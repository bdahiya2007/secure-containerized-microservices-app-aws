# Runbook – Product Service

Operational procedures for the Product Service deployed with the Terraform in `terraform/`.

All commands run from the **repository root** (`secure-containerized-microservices-app-aws/`). Terraform is run with
`-chdir=terraform` so you never need to `cd`.

## 0. Set variables

Set these once per shell session. They match the Terraform defaults (`aws_region` and `project_name`); change them if you
overrode either.

```bash
export AWS_REGION=us-east-1
export PROJECT=product-service
export CLUSTER="${PROJECT}-cluster"
export SERVICE="${PROJECT}"
export AWS_PAGER=""        # stop the AWS CLI opening a pager for long output
```

| Option / variable | What it does |
|---|---|
| `--region "$AWS_REGION"` | Targets the region explicitly, so the command does not depend on your default profile |
| `--no-cli-pager` | Same as `AWS_PAGER=""` for one command |
| `--output text` / `--output json` | Plain values for scripting, or full JSON |
| `--query '<JMESPath>'` | Filters the response to the fields you need |
| `terraform -chdir=terraform` | Runs Terraform in that directory without changing yours |
| `-var="name=value"` | Overrides a Terraform variable for this run only |
| `-raw` (`terraform output`) | Prints a bare string with no quotes, for use in `$(...)` |

## 1. Deploy from scratch

### Prerequisites
- AWS CLI v2 configured with credentials for the target account (`aws sts get-caller-identity --region "$AWS_REGION"` should succeed)
- Terraform >= 1.5 and Docker installed
- **IAM permissions to create roles.** The stack creates two ECS IAM roles, and the AWS-managed PowerUserAccess permission set excludes IAM, so `apply` fails with `AccessDenied` on `iam:CreateRole`.
  Add [iam/product-service-iam-policy.json](iam/product-service-iam-policy.json) (replace `ACCOUNT_ID` first) to the permission set, or use a role that can create IAM roles. You can test it cheaply with
  `terraform -chdir=terraform apply -target=aws_iam_role.task`.

### Steps

**Recommended order:** create the ECR repository and push the image first (steps 1 and 2 of the [ECR runbook](ECR_Runbook.md)), then run the full apply below, so the ECS tasks find an image when they start.
Doing the full apply first works too, but the tasks fail to start until the image is pushed.

1. **Create the infrastructure**
   ```bash
   terraform -chdir=terraform init
   terraform -chdir=terraform plan -out=tfplan
   terraform -chdir=terraform apply tfplan
   ```
   `alb_ingress_cidr` is required (your address as a `/32`): keep it in `terraform/demo.auto.tfvars` ([how](Logging_Runbook.md#step-0-set-variables)) or add `-var="alb_ingress_cidr=<your-ip>/32"` to the plan. `0.0.0.0/0` is refused unless `allow_public_alb = true`.
   `-out=tfplan` saves the plan so `apply` runs exactly what you reviewed, with no extra prompt.
   If the ECR repository already exists in Terraform's state (from the ECR runbook), the plan shows 31 resources to add and none to change. If you created it by hand, import it first.
   If you did the full apply before pushing an image, the ECS tasks fail to start until it is pushed. This is expected.

2. **Build and push the image**
   ```bash
   REPO=$(terraform -chdir=terraform output -raw ecr_repository_url)

   aws ecr get-login-password --region "$AWS_REGION" \
     | docker login --username AWS --password-stdin "${REPO%%/*}"

   docker build --platform linux/amd64 --tag "$REPO:latest" product-service
   docker push "$REPO:latest"
   ```
   `--platform linux/amd64` matters when building on an ARM machine, because the task
   definition runs on the default x86_64 Fargate platform. `${REPO%%/*}` strips the repository
   name, leaving the registry host that `docker login` needs.

3. **Force ECS to pick up the image and wait for it to settle**

   > Only for a service with the default ECS controller (`enable_blue_green = false`). `--force-new-deployment` is
   > rejected when CodeDeploy controls the service; there, tasks start on their own after the apply, and releases
   > go through the pipeline (section 4).
   ```bash
   aws ecs update-service --region "$AWS_REGION" --no-cli-pager \
     --cluster "$CLUSTER" --service "$SERVICE" --force-new-deployment

   aws ecs wait services-stable --region "$AWS_REGION" \
     --cluster "$CLUSTER" --services "$SERVICE"
   ```
   `--force-new-deployment` restarts the tasks even though the task definition is unchanged.
   `wait services-stable` polls every 15 seconds and gives up after about 10 minutes.

4. **Load the database schema** (see section 2).

5. **Verify** (see section 3).

## 2. Load the database schema

`product-service/db/schema.sql` creates and seeds the `products` table. RDS is in private subnets, so it cannot be reached from a laptop, and no `psql` is needed on your machine.
Terraform defines a one-off Fargate task, `product-service-migrate` (`terraform/migrate.tf`), that runs `node src/migrate.js` from **your own application image** inside the VPC. The image contains
`db/schema.sql` and the script, so no third-party image is pulled (the official `postgres` image was evaluated and rejected: it carried 85 known vulnerabilities, see
[vulnerability-scan-report.md](vulnerability-scan-report.md#third-party-image-evaluated-and-rejected-postgres18-alpine)). It uses the app security group
(the only one the database accepts), reads the password from Secrets Manager, connects over TLS, and logs to the `/ecs/product-service` log group under the stream prefix `migrate`.

**The image in ECR must be one built after `migrate.js` was added.** An image pushed earlier has no `db/` folder or `migrate.js`, and the task fails with `Cannot find module '/app/src/migrate.js'`.
Rebuild and push first (see [ECR_Runbook.md](ECR_Runbook.md)).

Run it once after the apply, when the RDS instance is `available`:

```bash
CLUSTER=$(terraform -chdir=terraform output -raw ecs_cluster_name)
SUBNETS=$(terraform -chdir=terraform output -json private_subnet_ids | tr -d '[]" \n')
APP_SG=$(terraform -chdir=terraform output -raw app_security_group_id)

TASK_ARN=$(aws ecs run-task --region "$AWS_REGION" --no-cli-pager \
  --cluster "$CLUSTER" --launch-type FARGATE \
  --task-definition "$(terraform -chdir=terraform output -raw migrate_task_definition)" \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$APP_SG],assignPublicIp=DISABLED}" \
  --query 'tasks[0].taskArn' --output text)
echo "$TASK_ARN"
```

| Option | What it does |
|---|---|
| `run-task --launch-type FARGATE` | Starts one copy of the task now, with no service to keep it running |
| `--task-definition` | The migrate task defined in Terraform |
| `awsvpcConfiguration={...}` | Puts the task in the private subnets with the app security group and no public IP |
| `--query 'tasks[0].taskArn'` | Keeps just the task's ARN, so the next commands can refer to it |

Wait for it to finish and check the result:

```bash
aws ecs wait tasks-stopped --region "$AWS_REGION" --cluster "$CLUSTER" --tasks "$TASK_ARN"

aws ecs describe-tasks --region "$AWS_REGION" --no-cli-pager --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].{exitCode:containers[0].exitCode,stopped:stoppedReason}' --output json

aws logs tail "/ecs/${PROJECT}" --region "$AWS_REGION" --log-stream-name-prefix migrate --since 15m --format short
```

**Expected:** `exitCode` of `0`, and a log line `{"level":"info","msg":"Schema applied"}`. The schema is safe to load again: the SQL only creates the table if it is missing and only seeds an empty table, so a second run also prints `Schema applied` and adds no rows.
This was verified in AWS (the first run loaded the 3 products). A non-zero `exitCode` means the SQL or the connection failed, and the log line `{"level":"error","msg":"Migration failed","error":"..."}` says why.

Then check `/products` (section 3). If you change `schema.sql`, `terraform apply` creates a new revision of the task definition, and the next `run-task` uses it.

## 3. Verify the deployment

**One command for all of it:** `scripts/verify-deployment.sh` runs about 35 read-only checks (Terraform drift, service and target health, the endpoints, security groups, the task role having no permissions, Auto Scaling, the dashboard, and each log) and prints PASS, FAIL or SKIP for each; optional logs that are switched off are skipped, not failed. It exits 0 only if nothing failed.
Pass `--skip-plan` to leave out the Terraform drift check. It changes nothing in AWS. Run it after every deploy; the manual commands below show what it checks. If the targets or the log check fail right after a scale-in or a redeploy, wait a minute and run it again (it already retries those). It sends no traffic that changes data; successful `/health` checks are not logged, so a log check on a quiet service may need a few requests first.

```bash
URL=$(terraform -chdir=terraform output -raw app_url)   # https://<your name> with enable_https, else http://<alb address>

curl --silent --show-error --include "$URL/health"     # expect 200 {"status":"ok"}
curl --silent --show-error --include "$URL/products"   # expect 200 and a JSON array
```

`--include` prints the response headers so you can see the status code; `--silent --show-error` hides the progress meter but still prints failures.

Check the service state:
```bash
aws ecs describe-services --region "$AWS_REGION" --no-cli-pager \
  --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].{desired:desiredCount,running:runningCount,events:events[:5].message}' \
  --output json
```

Check target health behind the load balancer:
```bash
TG_ARN=$(aws elbv2 describe-target-groups --region "$AWS_REGION" --no-cli-pager \
  --names "${PROJECT}-tg" --query 'TargetGroups[0].TargetGroupArn' --output text)

aws elbv2 describe-target-health --region "$AWS_REGION" --no-cli-pager \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{target:Target.Id,state:TargetHealth.State,reason:TargetHealth.Reason}' \
  --output table
```

## 4. Deploy a new version

**With the pipeline (`enable_blue_green = true`, the normal path):** merge the change to `main` (or run `gh workflow run deploy.yml`). GitHub Actions builds the image, pushes it tagged with the commit SHA, registers a new task definition revision and runs a CodeDeploy blue/green deployment. Terraform's `image_tag` is not used and is ignored by the service. Commands, verification and debugging: [Deployment.md](Deployment.md).

**Without the pipeline (`enable_blue_green = false`, rolling updates):**

1. Build and push with a unique tag (a git SHA works well):
   ```bash
   REPO=$(terraform -chdir=terraform output -raw ecr_repository_url)
   TAG=$(git rev-parse --short HEAD 2>/dev/null || echo v2)

   docker build --platform linux/amd64 --tag "$REPO:$TAG" product-service
   docker push "$REPO:$TAG"
   ```
2. Apply it:
   ```bash
   terraform -chdir=terraform apply -var="image_tag=$TAG"
   ```
3. Wait for the rollout:
   ```bash
   aws ecs wait services-stable --region "$AWS_REGION" \
     --cluster "$CLUSTER" --services "$SERVICE"
   ```

ECS replaces tasks gradually, starting new ones before stopping old ones.

## 5. Roll back

**With the pipeline:** a failed deployment rolls back by itself (traffic stays on the old tasks). To undo a release that went live, revert the commit through a pull request and let the pipeline redeploy, or stop a deployment in progress with `aws deploy stop-deployment --deployment-id <id> --auto-rollback-enabled`. See [Deployment.md](Deployment.md#5-roll-back).

**Without the pipeline:** re-apply with the previous tag:
```bash
terraform -chdir=terraform apply -var="image_tag=<previous-tag>"
```

List the tags that exist in ECR:
```bash
aws ecr describe-images --region "$AWS_REGION" --no-cli-pager \
  --repository-name "$PROJECT" \
  --query 'sort_by(imageDetails,&imagePushedAt)[].{tags:imageTags,pushed:imagePushedAt}' \
  --output table
```

Rollback by tag only works if you used unique tags. If you only pushed `latest`, the previous
image is untagged and must be redeployed by digest or rebuilt.

## 6. Scale

The service scales itself with Application Auto Scaling (`terraform/autoscaling.tf`): it keeps **2 to 4 tasks** and adds or removes tasks to hold average CPU near 60% and about 500 requests per task per minute
through the ALB. Scale-out reacts within a few minutes (60-second cooldown); scale-in is deliberately slower (300-second cooldown, and CloudWatch needs about 15 minutes of low load first).

Look at the current scaling setup and recent activity:
```bash
aws application-autoscaling describe-scalable-targets --region "$AWS_REGION" --no-cli-pager \
  --service-namespace ecs --resource-ids "service/$CLUSTER/$SERVICE" \
  --query 'ScalableTargets[0].{min:MinCapacity,max:MaxCapacity}' --output json

aws application-autoscaling describe-scaling-activities --region "$AWS_REGION" --no-cli-pager \
  --service-namespace ecs --resource-id "service/$CLUSTER/$SERVICE" \
  --query 'ScalingActivities[:5].{when:StartTime,cause:Cause,status:StatusCode}' --output table

aws ecs describe-services --region "$AWS_REGION" --no-cli-pager --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].{desired:desiredCount,running:runningCount}' --output json
```

**Change the limits** through Terraform:
```bash
terraform -chdir=terraform apply -var="autoscaling_min_capacity=1" -var="autoscaling_max_capacity=2"
```
`desired_count` only sets the starting number of tasks. Terraform ignores later changes to it (`ignore_changes`), because Auto Scaling owns that number. A manual `aws ecs update-service --desired-count` works
only until the next scaling decision, and it can't go outside the minimum and maximum.

**Test scaling** (this adds tasks, which cost about $0.012 an hour each). To make it react to a small test, apply with a low request target, then send traffic from the machine the ALB allows:
```bash
terraform -chdir=terraform apply -var="alb_ingress_cidr=<your-ip>/32" -var="autoscaling_requests_per_target=20"
URL=$(terraform -chdir=terraform output -raw app_url)
end=$((SECONDS+300))
while [ $SECONDS -lt $end ]; do seq 1 600 | xargs -P 30 -I{} curl -s -o /dev/null "$URL/health"; done
```
The traffic must last **at least 5 minutes**: the scale-out alarm needs three consecutive minutes above the target, so a shorter burst never triggers it (a 6,000-request burst that lasted two minutes did not).
Watch `running` rise toward 4 with the `describe-services` command above. In the AWS test the alarm fired about five minutes after the traffic started, and four tasks were running about a minute later.
Then restore the default (500) and expect the count to fall back to 2 after the scale-in delay. In the AWS test the first scale-in step (4 to 3 tasks) came about 18 minutes after the load ended, because the low-load alarm needs about 15 minutes of data;
target tracking then removes one task at a time.

**Database connections:** each task opens up to 10 connections, so 4 tasks can open 40. Check that this fits the database's connection limit before raising the maximum.

## 7. Logs

CloudWatch log group `/ecs/${PROJECT}` (14-day retention):
```bash
aws logs tail "/ecs/${PROJECT}" --region "$AWS_REGION" \
  --follow --since 30m --format short
```
`--follow` streams new lines, `--since 30m` starts 30 minutes back, `--format short` drops the stream name prefix.

**The application writes structured JSON lines** (one object per line, with `time`, `level`, `msg` and extra fields), so you can filter by field. Every request is logged with a `request_id`, `method`, `path`, `status` and `duration_ms`;
successful `/health` checks from the load balancer are not logged (they would be one line per task every 30 seconds); errors include `error` and, for a 500, a `stack`; and the database state is logged once when it changes (`Database unavailable`, `Database recovered`).
The `request_id` is the `X-Amzn-Trace-Id` that the ALB adds, so it matches the `trace_id` in the ALB access log (see section 7b), and it is returned to the client in the `X-Request-Id` response header. Query strings and the database password are never logged.
```bash
# Only errors (a JSON filter pattern on the level field)
aws logs tail "/ecs/${PROJECT}" --region "$AWS_REGION" --since 1h --filter-pattern '{ $.level = "error" }' --format short

# Every request that returned a 5XX
aws logs tail "/ecs/${PROJECT}" --region "$AWS_REGION" --since 1h --filter-pattern '{ $.msg = "request" && $.status >= 500 }' --format short

# Everything for one request, by the ID the client received in X-Request-Id
aws logs tail "/ecs/${PROJECT}" --region "$AWS_REGION" --since 1h --filter-pattern '{ $.request_id = "<id>" }' --format short
```
In the CloudWatch console, **Logs Insights** can aggregate the same fields, for example slow requests:
`fields @timestamp, path, status, duration_ms | filter msg = "request" | sort duration_ms desc | limit 20`.
Set `LOG_LEVEL=debug` in the task definition to also log successful health checks; the default is `info`. (This logging was added after the first AWS test, then deployed and verified: JSON lines appeared in CloudWatch, and a request's `request_id` matched its line in the ALB access log.)

## 7b. ALB access logs

The load balancer writes access logs to an S3 bucket (`terraform/logging.tf`). Files are compressed, are delivered every few minutes, and expire after 30 days. They show what the metrics can't, such as which target answered and why a 502 happened.

```bash
BUCKET=$(terraform -chdir=terraform output -raw log_bucket)

# List the newest log files (they are under alb/AWSLogs/<account>/elasticloadbalancing/<region>/<year>/<month>/<day>/)
aws s3 ls "s3://$BUCKET/alb/" --recursive --region "$AWS_REGION" | tail -5

# Download today's logs and show every ALB-generated or target 5XX with the reason
mkdir -p /tmp/alb-logs && aws s3 sync "s3://$BUCKET/alb/" /tmp/alb-logs --region "$AWS_REGION" --quiet
find /tmp/alb-logs -name '*.log.gz' -exec zcat {} + | awk '$9 ~ /^5/ || $10 ~ /^5/ {print $1, $2, "elb_status="$9, "target_status="$10, "target="$5, "error_reason="$NF}' | head
```

Each line is space separated: the time is field 2, the ALB's status code is field 9, the target's status code is field 10, and the target address is field 5. The `error_reason` for a 502 appears near the end of the line (for example `TargetClosedConnection`),
and the exact field position can shift, so check one raw line first with `zcat <file> | head -1`. Logs are delivered with a delay of a few minutes, and there is none for requests that never reached the ALB.
They cost only S3 storage, about $0.023 per GB-month; at this traffic that is a fraction of a cent.

### Central log bucket and the optional logs

The full step-by-step guide, with verification and troubleshooting, is the [logging runbook](Logging_Runbook.md); this is the short version.

The bucket is shared: each source writes under its own prefix. The extra sources are Terraform switches that default to **off** (demo only):

| Prefix or place | Source | Switch | Check that it is working |
|---|---|---|---|
| `alb/` | ALB access logs | always on | `aws s3 ls "s3://$BUCKET/alb/" --recursive` (files appear after about 5 minutes of traffic) |
| `cloudtrail/` | CloudTrail, multi-region | `enable_cloudtrail` | `aws cloudtrail get-trail-status --name product-service-trail` shows `IsLogging: true`; files under `cloudtrail/AWSLogs/` within about 15 minutes |
| A **separate bucket**, prefix `central-logs/` | S3 server access logs of the central bucket (who read or changed its files) | `enable_s3_access_logging` | `aws s3 ls "s3://$(terraform -chdir=terraform output -raw s3_access_log_bucket)/central-logs/"`. It fails silently if the policy is wrong, and delivery can take hours, so check for files rather than assuming. |
| CloudWatch Logs `/aws/rds/instance/product-service-db/postgresql` | RDS PostgreSQL and upgrade logs (not in S3) | `enable_rds_logs` | `aws logs tail /aws/rds/instance/product-service-db/postgresql --since 1h` |

Turn a switch on for a demo, then off again (each is an in-place change, and turning one off stops new logs but keeps the files until they expire). **Keep the switches and your ALB address in an untracked file, `terraform/demo.auto.tfvars`, and change a line there,
instead of passing `-var` options.** A `-var` applies to one run only, so a later plan without it quietly resets the switch. `alb_ingress_cidr` has no default (a plan without it fails, and `0.0.0.0/0` is refused unless `allow_public_alb = true`); in the first test it still defaulted to the open `0.0.0.0/0`, and a plan without the settings file reopened the load balancer to the internet.
The file and the checks to run before every plan are in the [logging runbook](Logging_Runbook.md#step-0-set-variables).
CloudTrail is account-wide. Check for an existing trail first with `aws cloudtrail describe-trails --include-shadow-trails`: the first trail's management events are free, a second costs about $2 per 100,000 events.

## 7a. Dashboard

Terraform creates a CloudWatch dashboard named `product-service` (`terraform/monitoring.tf`). Open it from the console link in the Terraform outputs:
```bash
terraform -chdir=terraform output -raw dashboard_url
```

| Widget | What it shows | Use it to |
|---|---|---|
| ECS CPU: reserved and utilized | Container Insights `CpuReserved` and `CpuUtilized` (CPU units, 1024 = 1 vCPU) | See how much of the reserved CPU the tasks use |
| ECS memory: reserved and utilized | `MemoryReserved` and `MemoryUtilized` (MB) | Spot memory pressure before tasks are killed |
| ECS tasks | `DesiredTaskCount`, `RunningTaskCount`, `PendingTaskCount` | Watch scaling and see whether running matches desired |
| ECS service CPU and memory % | `AWS/ECS` `CPUUtilization` and `MemoryUtilization` | See the values Auto Scaling tracks (target 60% CPU) |
| ALB request count | `RequestCount` and `RequestCountPerTarget` | See traffic, and the metric the requests scaling policy tracks |
| ALB errors | `HTTPCode_Target_4XX_Count` and 5XX, plus the ALB's own 4XX and 5XX | Find client errors (4XX) and server errors (5XX) |
| ALB target response time | Average and p95 `TargetResponseTime` | See latency |
| Target health | `HealthyHostCount` and `UnHealthyHostCount` | Confirm tasks pass their health checks |

**Two notes:** `CPUReservation` and `MemoryReservation` are published only for EC2-backed ECS clusters, not Fargate, so the dashboard uses Container Insights' Fargate equivalents (`CpuReserved`, `MemoryReserved`).
The only Lambda function is the optional database-password rotation function (`enable_aurora`; it has active X-Ray tracing and a 14-day log group), so there is no Lambda panel on the dashboard; the default deployment has no Lambda at all (see the note in `terraform/monitoring.tf`). New metrics can take a few minutes to appear. Example charts from the AWS test are in [E2E_Test_Results.md](E2E_Test_Results.md#charts). To render the dashboard's charts as PNG files without the console, use `aws cloudwatch get-metric-widget-image` with a widget's properties plus `start`, `end`, `width`, `height` and a `timezone` offset such as `-0700`.
Container Insights adds a small CloudWatch cost, and a custom dashboard costs about $3 a month after the free allowance.

## 8. Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| Tasks stop with `CannotPullContainerError` | No image in ECR, or wrong tag | Push the image (step 1.2), check `image_tag` |
| `terraform apply` fails with `AccessDenied` on `iam:CreateRole` (or another `iam:` action) | The role (for example PowerUserAccess) has no IAM permissions | Add [iam/product-service-iam-policy.json](iam/product-service-iam-policy.json) to the permission set. If a different `iam:` action is named, add it to the policy. |
| Tasks stop with a Secrets Manager error | Execution role cannot read the DB secret | Check `aws_iam_role_policy.read_db_secret` and that the secret exists |
| ALB returns 502/503 | No healthy targets | Check target health (section 3) and task logs (section 7) |
| Targets unhealthy | `/health` returning 503, so the app cannot reach the DB | Check the DB is `available`, security group allows 5432 from the app, credentials valid |
| `/products` returns 500, `/health` is OK | `products` table missing | Load the schema (section 2) |
| Migration task stops with a non-zero exit code | SQL error, or the database isn't reachable yet | Read the `migrate` log stream (section 2). Wait until the RDS instance is `available` and run it again. |
| Migration task fails with `Cannot find module '/app/src/migrate.js'` | The image in ECR was pushed before `migrate.js` and `db/` were added | Rebuild and push the image (ECR runbook), then run the task again |
| Migration task fails with `CannotPullContainerError` for the product-service image | No image with that tag in ECR, or the NAT or route table is broken | Check `image_tag` and the ECR repository, then the private route table |
| Tasks cannot reach ECR or Secrets Manager | NAT gateway or private route table problem | Check the private route table has a `0.0.0.0/0` route to the NAT |
| `terraform apply` fails on RDS version | Version not offered in the region | See the command below |

Why a task stopped:
```bash
TASK_ARN=$(aws ecs list-tasks --region "$AWS_REGION" --no-cli-pager \
  --cluster "$CLUSTER" --service-name "$SERVICE" --desired-status STOPPED \
  --query 'taskArns[0]' --output text)

aws ecs describe-tasks --region "$AWS_REGION" --no-cli-pager \
  --cluster "$CLUSTER" --tasks "$TASK_ARN" \
  --query 'tasks[0].{status:lastStatus,reason:stoppedReason,container:containers[0].reason}' \
  --output json
```

Database status:
```bash
aws rds describe-db-instances --region "$AWS_REGION" --no-cli-pager \
  --db-instance-identifier "${PROJECT}-db" \
  --query 'DBInstances[0].{status:DBInstanceStatus,version:EngineVersion,class:DBInstanceClass}' \
  --output json
```

Engine versions RDS offers for PostgreSQL:
```bash
aws rds describe-db-engine-versions --region "$AWS_REGION" --no-cli-pager \
  --engine postgres --query 'DBEngineVersions[].EngineVersion' --output text \
  | tr '\t' '\n' | sort -V | tail -5
```

## 9. Rotate the database password

The password is managed by RDS in Secrets Manager and rotates by itself every 7 days. To rotate it now:
```bash
aws secretsmanager rotate-secret --region "$AWS_REGION" --no-cli-pager \
  --secret-id "$(terraform -chdir=terraform output -raw db_secret_arn)"

```
Once the app reads the secret at runtime (see [Secrets.md](Secrets.md)) no restart is needed: the running tasks fetch the new
password on the first failed login and retry. If your tasks still get the password injected by ECS (before that rollout), restart them so
they pick up the new value: `aws ecs update-service ... --force-new-deployment` with the default ECS controller, or, with
`enable_blue_green = true` (which rejects that flag), run the Deploy workflow (`gh workflow run deploy.yml`).

## 10. Tear down

> **With disaster recovery on** (`enable_dr_replica` or `enable_dr_failover`, a Region B stack in `terraform/region-b`): destroy **Region B first** (`terraform -chdir=terraform/region-b destroy`), and only then the main stack below. If a failover left Region B as the database writer, fail back first. Afterwards delete the `rds:unplanned-global-failover-...` snapshot a failover leaves behind, and run the leftover checks in **both** Regions (us-east-1 and us-west-2). The full steps are in [DR_Runbook.md](DR_Runbook.md), section 5, and the whole deploy-test-drill-destroy order is in section 7.

```bash
terraform -chdir=terraform plan -destroy
terraform -chdir=terraform destroy
```
`plan -destroy` shows what will be deleted first; `destroy` asks you to type `yes`.

This deletes the database and its data (`skip_final_snapshot = true`), the ECR images and the log buckets with their contents. It takes about 10 to 15 minutes. If it stops with `ResourceInUse` on the green target group, run `plan -destroy` and `destroy` again: the listener that CodeDeploy pointed at it is gone by then (the Terraform now orders this correctly). The NAT gateway and ALB
are the main hourly costs, so destroy demo environments promptly (about $0.14/hour in total).

Confirm nothing is left billing:
```bash
aws ec2 describe-nat-gateways --region "$AWS_REGION" --no-cli-pager \
  --filter Name=state,Values=available,pending \
  --query 'NatGateways[].NatGatewayId' --output text

aws elbv2 describe-load-balancers --region "$AWS_REGION" --no-cli-pager \
  --query 'LoadBalancers[].LoadBalancerName' --output text
```
Both should print nothing for this project.
