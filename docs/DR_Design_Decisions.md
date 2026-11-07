# Disaster recovery: design decisions (Phase B)

**Status: decisions only. Nothing in this page is built or deployed.** It records the choices made after the [exploration](Disaster_Recovery_Exploration.md), so the Terraform that follows is written once. Costs are **estimates from list prices**, not measured; items marked *verify* are assumptions to confirm while writing the code.

## Decisions

| # | Question | Decision | Why |
|---|---|---|---|
| 1 | Which option to build | **Aurora Global Database** (the exercise's requirement). The RDS read replica and backup replication stay documented as cheaper alternatives | It is what Step 2 asks for: RPO seconds, RTO minutes |
| 2 | Database password and rotation | **A self-managed secret in Region A, replicated to Region B, with our own rotation function** | Secrets Manager managed credentials are not supported with Aurora Global Database. The app keeps reading the secret at runtime, and the task role keeps its single `GetSecretValue` permission |
| 3 | Terraform layout | **Keep the current stack and add a separate Region B stack** with its own state. The global cluster, the primary cluster and the secret stay in the main stack | The smallest change to working code. Destroy Region B first |
| 4 | Failover trigger | **Manual, with a written runbook** | Automation adds cost and the risk of a wrong automatic failover |
| 5 | HTTPS | **HTTPS in both Regions**: Region B gets its own ACM certificate and a `usw2.` test name; Region A keeps `use1.` and the main name | The failover path must be encrypted end to end like the rest of the project |
| 6 | Health check and exposure | **Both ALBs stay restricted to the owner's address.** The Route 53 failover check is driven by a **CloudWatch alarm**, not by a probe. A public window is for a demo only | Route 53's health checkers cannot reach an ALB that admits one address, and the API has no authentication yet |
| 7 | Region B size | **One task kept running**, in **private subnets behind a NAT gateway** (the same posture as Region A) | One task costs about $0.012 an hour and proves the image, the replicated secret and the read-only database work together before a disaster. A NAT gateway costs about $0.27 over the session and keeps Region B as secure as Region A |
| 8 | Aurora capacity | **Low capacity on both clusters** (0.5 to 1 ACU minimum, a small maximum, about 4), with a replication-lag test in the drill | AWS recommends 8 ACU for the primary of a global database, which is about $0.96 an hour. The lag result decides whether to raise it, and it is recorded either way |
| 9 | Targets | **RPO about 1 minute, RTO 30 minutes or less**, measured in the drill | AWS says RPO is "seconds" and RTO "minutes" for a failover; the targets leave margin |
| 10 | Budget and timing | **One session of 5 to 6 hours, with a $5 to $10 budget**, and the budget alert raised first | Estimated $3 to $4 with retries. The writing and offline review cost nothing |

## Target architecture

```
                 Route 53: app name (failover routing, TTL 60 s)
                    |  primary (alarm healthy)         |  secondary (alarm in alarm)
                    v                                  v
   +---------------- us-east-1 ----------------+   +---------------- us-west-2 ----------------+
   | ALB (HTTPS, ACM)  -> ECS Fargate 2 to 4   |   | ALB (HTTPS, own ACM)  -> ECS Fargate 1    |
   | private subnets, NAT                      |   | private subnets, NAT                      |
   | Aurora Serverless v2  WRITER  ------------+--->  Aurora Serverless v2  READ-ONLY (own KMS) |
   | secret (primary)  -----------------------+--->  secret (replica)                           |
   | ECR  --------------------------------------+-->  ECR (replicated images)                   |
   +-------------------------------------------+   +-------------------------------------------+
   CloudWatch alarm on Region A's healthy hosts drives the Route 53 health check
```

The new Region B stack holds its network, ALB, ECS service, KMS key, Aurora secondary cluster, certificate, ECR replication and `usw2.` record. The main stack gains the global cluster, the Aurora primary (replacing RDS), the self-managed secret and its replica, the failover records and the alarm.

## Design notes

- **Secret.** Create the secret ourselves and replicate it to Region B (replicas receive new versions automatically). The password never reaches Terraform state: the AWS provider has write-only arguments for it, `master_password_wo` on the cluster and `secret_string_wo` on the secret version, both needing **Terraform 1.11 or later** (the repository requires 1.10 today, so the minimum is raised in the infrastructure piece; *verify* an ephemeral random-password source for the value). The Region B task reads the **replica's** ARN.
- **Rotation function (written, tested, not deployed).** [`lambdas/db-rotation/`](../lambdas/db-rotation/lambda_function.py) is a Secrets Manager rotation function in Python with 14 offline unit tests. It changes the password through the **RDS control plane** (`ModifyDBCluster`), not by logging in, so it needs no VPC, no database driver and no network path to the cluster; Aurora Global Database replicates the change to the secondary. **Trade-off:** `testSecret` cannot try a login with the new password (the RDS Data API, the only login-free way to run SQL, always uses the secret's *current* version), so it checks that the cluster is available and the change applied. The application's existing retry after a failed login covers the window, and the drill rotates a password end to end. The Data API was checked and works on a global cluster's primary writer (Aurora PostgreSQL 18.3 and later, us-east-1 and us-west-2, not on T instance classes), so it remains an option for a later login test.
- **Health check.** A Route 53 health check that follows a CloudWatch alarm on Region A's load balancer (for example, no healthy hosts). Configured so that no data counts as unhealthy (`treat_missing_data = breaching` on the alarm, `insufficient_data_health_status = Unhealthy` on the check), so the name moves when the whole Region is down; *verify* this in the drill by setting the alarm to ALARM by hand and by stopping the Region A tasks.
- **Database cutover.** The app already takes the endpoint from `DB_HOST` and retries once after a failed login. The Region B service uses Region B's cluster endpoint, which is read-only until the failover promotes it; `GET /products` only reads, so Region B can serve before the promotion.
- **Images.** ECR cross-Region replication, so Region B can always pull the current image. The pipeline still deploys to Region A; how Region B's service picks up a new release is a Phase C decision.
- **Destroy order.** Region B first, then the global cluster's secondary, then Region A. One cluster of a global database cannot be stopped on its own, so the only way to stop the cost is to destroy everything.

## Estimated cost of the paid session

| Item | Per hour |
|---|---|
| Region A stack (NAT, ALB, tasks) | about $0.15 |
| Aurora, two clusters at low capacity | about $0.12 to $0.24 |
| Region B (NAT, ALB, one task) | about $0.08 |
| **Total** | **about $0.35 to $0.50, so about $2.10 to $3 for 6 hours** |

With retries and extras, about $3 to $4. Leftover keys and secrets cost cents. The month's budget is already about $5 spent, so the alert is raised to about $10 before the session.

## Drills and evidence (Phase E)

1. Apply, load the schema, verify both Regions (`verify-deployment.sh` extended for two Regions).
2. Check Region B directly through its `usw2.` name before any failover.
3. **Switchover** to Region B and back (RPO 0): time the gap with a request probe.
4. **Failover drill** with `failover-global-cluster --allow-data-loss`: measure real RTO and RPO from CloudWatch, including `AuroraGlobalDBRPOLag` under load.
5. Capture the charts, record the results as in [Rollback_Test.md](Rollback_Test.md), then destroy everything and check for leftovers in both Regions.

## Phase C progress

| Piece | Status |
|---|---|
| Rotation function and tests (`lambdas/db-rotation/`), run in CI, scanned by Semgrep (Python rules) | **Written and tested offline** |
| Aurora replacing RDS in Region A, the self-managed secret and replica, the rotation function's deployment, schedule and permissions (`terraform/aurora.tf`, switch `enable_aurora`, off by default; the minimum Terraform version is now 1.11 and the `archive` provider is added) | **Written, validated and planned offline** (plan with the switch off: 68 to add; on: 77 to add; no password in the plan). **Not applied.** **Confirmed 2026-11-07:** Aurora PostgreSQL `18.6` (the default and the newest 18.x minor) is offered in us-east-1 and us-west-2 with Global Database and Serverless v2 support, and the scans pass in CI. **To confirm before applying:** the `moved` block against a real RDS state. `verify-deployment.sh` does not know about Aurora yet (a later piece) |
| Region B stack (`terraform/region-b/`, its own state), in three parts: **3a the network** (VPC, subnets, NAT, S3 endpoint, security groups; PR #38), **3b the database** (KMS key, Aurora secondary cluster and instance; reads the main stack's outputs), **3c the app** (ECR repository, load balancer with its own certificate and `usw2.` name, ECS cluster and one task; the main stack gets the ECR replication rule) | **3a and 3b merged, 3c written** (not applied; Region B cannot be planned until the main stack's Aurora exists, because it reads that stack's outputs) |
| **Route 53 failover (piece 4):** the PRIMARY record with a health check that follows a CloudWatch alarm on healthy targets (`terraform/failover.tf`, `enable_dr_failover`), the SECONDARY record in the Region B stack, and Region B's certificate also covering the main name | **Written** (not applied); how the check behaves when the whole Region is down is configured (missing data counts as breaching, insufficient data as unhealthy) but only proven in the drill |
| **The Aurora-aware verify script, the failover runbook and the drill probe (piece 5):** `scripts/verify-deployment.sh` now checks HTTPS, the Aurora global-database member, the secret's rotation and replica, and the failover wiring when those are on; [`DR_Runbook.md`](DR_Runbook.md) is the step-by-step plan for the paid session; `scripts/dr-probe.sh` records every request so the gap is measured | **Written** (not run: the new verify branches and the runbook have never run against a real deployment) |

## Phases that follow

| Phase | What | Cost |
|---|---|---|
| **C** | Write the Terraform and docs, validate and review plans offline. Switches default to off | none |
| **D** | Apply the demo cost choices above in code | none |
| **E** | The paid session: apply (by the owner), drills, evidence | about $3 to $4 |
| **F** | Results doc, updated diagrams and runbook, destroy in both Regions, leftover check | none |

## Out of scope

Automated failover, a WAF, API authentication (the ALBs stay restricted instead), and more than two Regions.
