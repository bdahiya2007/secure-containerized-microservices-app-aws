# Disaster recovery runbook: build, drill, record, destroy

**Status: written, not yet run.** Nothing here has been applied or tested in AWS. It is the plan for the one paid session described in [DR_Design_Decisions.md](DR_Design_Decisions.md): about 5 to 6 hours and an estimated $3 to $4 (about $0.35 to $0.50 an hour), with the budget alert raised first. Commands use placeholders in angle brackets; the real names and addresses stay in your untracked `demo.auto.tfvars` and `terraform.tfvars`.

**Ground rules.** The owner reviews each plan and runs each `terraform apply` and `destroy` in their own terminal. Do not run `terraform apply` on either stack in the middle of a drill: a failover changes which cluster is the writer, so Terraform's picture is wrong until you fail back.

## 0. Before the session

- [ ] Raise the AWS budget alert to about $10, and decide the stop time (a 6-hour limit).
- [ ] `aws ecr describe-registry`: the main stack's replication rule **replaces** any existing registry replication configuration. Stop here if the account already has one that matters.
- [ ] Docker is running (to build the first image), and `terraform/backend.hcl` and `terraform/region-b/backend.hcl` exist.
- [ ] `demo.auto.tfvars` has `enable_https`, `app_domain`, `hosted_zone_name`, `enable_aurora = true`, `enable_dr_replica = true` and `enable_dr_failover = true`. `terraform/region-b/terraform.tfvars` has `state_bucket`, `alb_ingress_cidr`, `hosted_zone_name`, `app_domain` (the `usw2.` name), `failover_domain` (the main name) and, later, `enable_failover_record = true`.
- [ ] Your public address has not changed since the tfvars were written ([Deployment.md](Deployment.md), section 3a).

## 1. Build (about 45 to 60 minutes, mostly waiting)

1. **ECR first, in this order.** (a) Main stack: `terraform -chdir=terraform apply -target=aws_ecr_repository.app -target=aws_ecr_replication_configuration.dr` (the rule must exist before the first image is pushed). (b) Region B stack: `terraform -chdir=terraform/region-b apply -target=aws_ecr_repository.app -target=aws_ecr_lifecycle_policy.app`. **Region B's repository must exist before the first push**: otherwise replication creates it on its own and the Region B stack's later create fails with "already exists". (c) Build and push the first image by hand ([ECR_Runbook.md](ECR_Runbook.md)) and check that it appears in Region B (`aws ecr describe-images --region us-west-2 --repository-name product-service`).
2. **Main stack, everything.** Plan, review, apply. Expect about 80 resources; the Aurora cluster and its secret take the longest. Then load the schema with the migration task ([runbook.md](runbook.md)).
3. **Check the replica secret exists in Region B:** `aws secretsmanager describe-secret --region us-west-2 --secret-id product-service/aurora-master`.
4. **Region B stack.** `cd terraform/region-b`, `terraform init -backend-config=backend.hcl`, plan, review, apply (`enable_failover_record` off for now). Expect the Aurora secondary to take 15 to 20 minutes.
5. **Verify both Regions:** `scripts/verify-deployment.sh --skip-plan` for Region A, and check Region B directly (drill 1).

## 2. Drills

Start the probe in a second terminal before each drill and keep it running: `scripts/dr-probe.sh https://<main name> 1800 probe.csv`. Record the wall-clock time of every action.

**Drill 1: Region B works before any failover.** `curl https://<usw2 name>/health` and `/products` answer 200 over HTTPS (the task reads the replica secret and the secondary's reader endpoint). Look at the replication lag now: see section 3.

**Drill 2: a password rotation end to end.** Rotate by hand (`aws secretsmanager rotate-secret --secret-id product-service/aurora-master`), watch the rotation function's log group, and send requests throughout, as in the earlier RDS tests ([Secrets.md](Secrets.md)). Expect it to take about 2 to 4 minutes (RDS resets the credentials for about 90 seconds), with one expected "not applied yet" error from `testSecret` in the log before it succeeds. **If the secret is still `AWSPENDING` after 5 minutes, stop**: that is the retry livelock the first real run found; check `aws rds describe-events` for repeated "Reset master credentials" events. Confirm the app keeps serving and that the replica secret in Region B got the new version.

**Drill 3: a planned switchover, and back (RPO 0).**
```bash
aws rds switchover-global-cluster --region us-east-1 --global-cluster-identifier product-service-global \
  --target-db-cluster-identifier <the Region B cluster ARN>
```
Wait until the Region B cluster is the writer (`aws rds describe-global-clusters`), note the time, then switch back the same way with the Region A cluster as the target. The probe (which only reads) should show little or no gap.

**Drill 4: a DNS failover rehearsal (no database change).** Add the SECONDARY record (`enable_failover_record = true` in the Region B stack, apply). Then stop Region A's service: `aws ecs update-service --region us-east-1 --cluster product-service-cluster --service product-service --desired-count 0`. After about 3 minutes the alarm `product-service-no-running-tasks` goes to ALARM, Route 53's health check turns unhealthy, and the main name starts answering with Region B (the probe's remote IP changes, and **HTTPS must still verify**: Region B's certificate covers the main name). Restore with `--desired-count 2`. Setting the alarm state by hand (`aws cloudwatch set-alarm-state`) is only a quick look: the alarm re-evaluates every minute and goes back, so the stopped service is the reliable rehearsal.

**Drill 5: the database failover (data loss allowed).** Record the current replication lag first (section 3). Then:
```bash
aws rds failover-global-cluster --region us-west-2 --global-cluster-identifier product-service-global \
  --target-db-cluster-identifier <the Region B cluster ARN> --allow-data-loss
```
Wait for the Region B cluster to become the writer, scale the Region B service up (`aws ecs update-service --region us-west-2 --cluster product-service-b-cluster --service product-service-b --desired-count 2`), and check that `https://<main name>/products` answers. **Fail back** (a switchover with Region A as the target) before any Terraform command: Terraform expects Region A to be the writer.

## 3. Measuring

- **RPO.** `AuroraGlobalDBRPOLag` is published for the secondary cluster, in milliseconds. Read the maximum over the minute before the failover, and while the probe or a write load is running:
  ```bash
  aws cloudwatch get-metric-statistics --region us-west-2 --namespace AWS/RDS --metric-name AuroraGlobalDBRPOLag \
    --dimensions Name=DBClusterIdentifier,Value=product-service-b-aurora --statistics Maximum --period 60 \
    --start-time <UTC> --end-time <UTC>
  ```
  Low capacity (0.5 to 1 ACU) may let the lag grow under write load; if it does, raise `aurora_min_capacity` and record both results.
- **RTO.** From the moment you stop Region A (or run the failover command) to the first `200` that the probe gets from a Region B address. `scripts/dr-probe.sh --summary probe.csv` prints the longest run of failed requests; the CSV timestamps give the rest. Break it into detection (alarm and health check), database promotion and service scale-up, so the design's 30-minute target can be checked part by part.
- **Targets to compare with:** RPO about 1 minute, RTO 30 minutes or less.

## 4. Evidence to keep

Save the probe CSV and its summary, the timeline of your actions, the lag readings, and CloudWatch charts (`aws cloudwatch get-metric-widget-image`, as in [Rollback_Test.md](Rollback_Test.md)) into `docs/images/`, and write the results in a new `docs/DR_Test_Results.md`, including anything that did not work. Report the measured RPO and RTO honestly, even if they miss the targets.

## 5. Teardown (do not skip, and do not leave it overnight)

1. **Fail back first** if the last drill left Region B as the writer.
2. `terraform destroy` in `terraform/region-b` (Region B first), then in `terraform` (the main stack; `force_destroy` detaches the global cluster's members).
3. Check both Regions for leftovers (every list should be empty or hold only other projects' items; KMS keys wait 7 days to delete and show as pending):
   ```bash
   for R in us-east-1 us-west-2; do echo "== $R"
     aws ec2 describe-nat-gateways --region $R --filter Name=state,Values=available,pending --query 'length(NatGateways)'
     aws elbv2 describe-load-balancers --region $R --query 'LoadBalancers[].LoadBalancerName'
     aws ec2 describe-addresses --region $R --query 'length(Addresses)'
     aws rds describe-db-clusters --region $R --query 'DBClusters[].DBClusterIdentifier'
     aws rds describe-db-instances --region $R --query 'DBInstances[].DBInstanceIdentifier'
     aws rds describe-db-cluster-snapshots --region $R --query 'DBClusterSnapshots[].DBClusterSnapshotIdentifier'
     aws ecr describe-repositories --region $R --query 'repositories[].repositoryName'
     aws ecs list-clusters --region $R --query 'clusterArns'
     aws secretsmanager list-secrets --region $R --query 'SecretList[].Name'
     aws acm list-certificates --region $R --query 'CertificateSummaryList[].DomainName'
     aws logs describe-log-groups --region $R --log-group-name-prefix /ecs/product-service --query 'logGroups[].logGroupName'
   done
   ```
   and check the Route 53 zone for the app names (`aws route53 list-resource-record-sets --hosted-zone-id <zone id>`): only the records you meant to keep.
4. Delete the saved plan files (they hold your address and account details), and check the next day's bill.

## 6. If something goes wrong

- **A step is stuck or an apply fails:** stop, do not retry blindly; paste the error and decide. A partly built stack still costs about $0.35 to $0.50 an hour.
- **The probe shows no answer from either Region:** check the Region A alarm, the Route 53 health check, and that the SECONDARY record exists; test `https://<usw2 name>` directly.
- **A destroy stops with `ResourceInUse`:** run the plan and the destroy again ([Deployment.md](Deployment.md), section 7).
- **Out of budget or time:** destroy everything, record what you learned, and finish the evidence from the notes.
