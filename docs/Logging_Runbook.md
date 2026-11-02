# Logging runbook

How to turn on, verify, read and turn off the logs for the Product Service. All commands run from the **repository root** (`secure-containerized-microservices-app-aws/`). Account ID and your IP address are never written here; use the variables.

## What logs exist

| Log | Answers | Switch (default) | Where it is stored | Retention | Approximate cost |
|---|---|---|---|---|---|
| **ALB access logs** | Which client called which URL, which task answered, with what status and timing; the reason for a 502 | always on | Central bucket, prefix `alb/` | 30 days (`log_retention_days`) | cents (S3 storage only) |
| **CloudTrail** | Who made which API call in the AWS account (created, changed, deleted things) | `enable_cloudtrail` (`false`) | Central bucket, prefix `cloudtrail/` | 90 days (`cloudtrail_log_retention_days`) | free for the account's **first** trail, otherwise about $2 per 100,000 events |
| **S3 server access logs** | Who read or changed the files in the central log bucket | `enable_s3_access_logging` (`false`) | A **separate small bucket**, prefix `central-logs/` | 30 days | cents |
| **Application logs** | What the app saw: each request (with a `request_id` that matches the ALB's `trace_id`), errors with a stack for a 500, and database up/down changes, as JSON lines | always on | CloudWatch Logs `/ecs/product-service` | 14 days | about $0.50 per GB ingested; megabytes at this traffic |
| **RDS PostgreSQL and upgrade logs** | Database errors, checkpoints, upgrades | `enable_rds_logs` (`false`) | **CloudWatch Logs** (RDS cannot write to S3 directly) | 14 days | about $0.50 per GB ingested; cents for a quiet database |

The extra logs are switches that default to **off**, so a default deployment costs nothing extra. Turn them on for a demo, check that they work, then turn them off again.

## Step 0: Set variables

```bash
export AWS_REGION=us-east-1
CLUSTER=product-service-cluster
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '\n')
```
`MY_IP` limits the load balancer to your address for the test. Don't paste it into any file that is committed.

### Keep the switches in one untracked file

Terraform `-var` options apply **only to that one run**: a later `apply` without them sets a switch back to `false`, which would turn a log off again. To avoid that, keep your settings in a `.tfvars` file. `.gitignore` excludes `*.tfvars`, so it is never committed.

```bash
cat > terraform/demo.auto.tfvars <<EOF
alb_ingress_cidr         = "$MY_IP/32"
enable_cloudtrail        = false
enable_s3_access_logging = false
enable_rds_logs          = false
EOF
```
Terraform loads `*.auto.tfvars` automatically. To turn a log on or off, change that one line to `true` or `false` and run `terraform -chdir=terraform apply`. (Re-run the `cat` command if your IP address changes.)

**Check that the file was written before you plan:**
```bash
grep -c "enable_" terraform/demo.auto.tfvars      # must print 3
```
> **Note: `alb_ingress_cidr` is required and has no default.** A plan made without this file now stops with "No value for required variable", and a value of `0.0.0.0/0` is refused unless you also set `allow_public_alb = true`. This safeguard was added after the first test, where the variable still defaulted to `0.0.0.0/0`: a missing file made a chained command fail silently, and the next plan changed the ALB's security group from one `/32` address to `0.0.0.0/0` and was applied.
> **Every time, read the plan and confirm `aws_security_group.alb` is not changing to `0.0.0.0/0`.** After an apply you can check the live rule with:
> ```bash
> aws ec2 describe-security-groups --region "$AWS_REGION" \
>   --group-ids "$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --names product-service-alb --query 'LoadBalancers[0].SecurityGroups[0]' --output text)" \
>   --query 'SecurityGroups[0].IpPermissions[].IpRanges[].CidrIp' --output text
> ```
> It should print your own address with `/32`, not `0.0.0.0/0`.

## Step 1: Apply the central log bucket and ALB logging

This creates the central bucket and points the load balancer at it. If you already applied the earlier ALB-only bucket, the plan replaces that bucket (a few minutes of old logs are deleted).

```bash
terraform -chdir=terraform plan -out=logging.tfplan
terraform -chdir=terraform apply logging.tfplan
```
`-out=logging.tfplan` saves the plan so `apply` runs exactly what you reviewed (the file ends in `.tfplan`, which `.gitignore` excludes). With all switches off expect about **5 to add, 1 to change** (the load balancer), plus 5 to destroy if the old bucket exists. Read the plan before applying.

## Step 2: Verify the ALB access logs

```bash
BUCKET=$(terraform -chdir=terraform output -raw log_bucket)

# 1. The load balancer is configured to log
aws elbv2 describe-load-balancer-attributes --region "$AWS_REGION" --no-cli-pager \
  --load-balancer-arn "$(aws elbv2 describe-load-balancers --region "$AWS_REGION" --names product-service-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)" \
  --query "Attributes[?starts_with(Key,'access_logs')].{key:Key,value:Value}" --output table
```
Expect `access_logs.s3.enabled` = `true`, with the central bucket name and prefix `alb`.

```bash
# 2. Generate some traffic (the load balancer only logs requests that reach it)
URL=$(terraform -chdir=terraform output -raw app_url)
for i in $(seq 1 20); do curl -s -o /dev/null "$URL/health"; curl -s -o /dev/null "$URL/products"; curl -s -o /dev/null "$URL/nope"; done

# 3. Wait about 5 minutes, then list the files
aws s3 ls "s3://$BUCKET/alb/" --recursive --region "$AWS_REGION" | tail -5
```
Files are compressed (`.log.gz`) and delivered every few minutes, under `alb/AWSLogs/<account>/elasticloadbalancing/<region>/<year>/<month>/<day>/`. No files after 10 minutes: see Troubleshooting.

**Verified in AWS (2026-10-31):** 60 requests (20 each to `/health`, `/products` and `/nope`) produced log files in about one minute, and the status counts matched exactly (40 with status 200, 20 with status 404). AWS also writes a file called `ELBAccessLogTestFile` to check that it can write to the bucket; ignore it.

**Read them:** each line is space separated; the time is field 2, the load balancer's status code is field 9, the task's status code is field 10, and the task address is field 5 (these positions were checked against real logs). The request is in quotes, so use `awk -F'"'` to get the method and URL. Check one raw line first, because field positions can shift.
```bash
mkdir -p /tmp/alb-logs && aws s3 sync "s3://$BUCKET/alb/" /tmp/alb-logs --region "$AWS_REGION" --quiet
find /tmp/alb-logs -name '*.log.gz' -exec zcat {} + | head -1                                   # one raw line
find /tmp/alb-logs -name '*.log.gz' -exec zcat {} + | awk '{print $9}' | sort | uniq -c           # count of responses by status code
find /tmp/alb-logs -name '*.log.gz' -exec zcat {} + | awk '$9 ~ /^5/ || $10 ~ /^5/ {print $2, "elb="$9, "target="$10, "target_addr="$5}'   # any 5XX
```
For a 502, 503 or 504 the log line ends with an `error_reason`, which is what the CloudWatch metrics cannot show.

## Step 3: CloudTrail (optional)

CloudTrail is **account-wide**, not project-specific. First check whether the account already has a trail:
```bash
aws cloudtrail describe-trails --region "$AWS_REGION" --include-shadow-trails --no-cli-pager --query 'trailList[].Name' --output text
```
No output means there is no trail, so a new one is the first and its management events are **free**. If a trail exists, a second copy of management events costs about $2 per 100,000 events: stop and decide first.

Turn it on (edit `terraform/demo.auto.tfvars`: `enable_cloudtrail = true`), then:
```bash
terraform -chdir=terraform plan -out=trail.tfplan
terraform -chdir=terraform apply trail.tfplan
```
Expect the trail and the bucket policy statements for CloudTrail (about **1 to add, 1 to change**). CloudTrail checks the bucket policy when the trail is created, so a wrong policy fails immediately with `InsufficientS3BucketPolicyException`.

```bash
# The trail is logging
aws cloudtrail get-trail-status --region "$AWS_REGION" --name product-service-trail --no-cli-pager \
  --query '{logging:IsLogging,lastDelivery:LatestDeliveryTime,error:LatestDeliveryError}' --output json

# Make a few recorded calls, then wait up to about 15 minutes for the first file
aws ec2 describe-vpcs --region "$AWS_REGION" --query 'length(Vpcs)' --output text
aws s3 ls "s3://$BUCKET/cloudtrail/" --recursive --region "$AWS_REGION" | tail -5
```
Expect `IsLogging: true` and `.json.gz` files under `cloudtrail/AWSLogs/<account>/CloudTrail/<region>/...`, plus digest files under `CloudTrail-Digest/` (used for tamper checking).

**Verified in AWS (2026-10-31):** the trail reported `IsLogging: true`, and the first log file (75 events) arrived about 3 minutes after three test API calls. Reading it showed each test call with its time, service, call name, caller, source IP and `readOnly` flag, so the reader snippet below works.

**Read the events** (this prints time, service and call name, and who made it):
```bash
mkdir -p /tmp/trail-logs && aws s3 sync "s3://$BUCKET/cloudtrail/" /tmp/trail-logs --region "$AWS_REGION" --quiet
find /tmp/trail-logs -name '*_CloudTrail_*.json.gz' -exec zcat {} + | python3 -c '
import sys, json
for line in sys.stdin:
    for r in json.loads(line).get("Records", [])[:200]:
        who = (r.get("userIdentity") or {}).get("arn", "?").split("/")[-1]
        print(r["eventTime"], r["eventSource"], r["eventName"], who)
' | tail -15
```
Digest files are written about every hour. Once they exist you can check that no log file was altered:
```bash
TRAIL_ARN=$(aws cloudtrail describe-trails --region "$AWS_REGION" --trail-name-list product-service-trail --query 'trailList[0].TrailARN' --output text)
aws cloudtrail validate-logs --region "$AWS_REGION" --trail-arn "$TRAIL_ARN" --start-time "$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
```
It reports each digest file as valid or not.

**Verified in AWS (2026-10-31):** over the first 3 hours it reported **3/3 digest files valid and 41/41 log files valid**.

## Step 4: S3 server access logs (optional)

These record who reads or changes the files in the central bucket. They go to a **separate small bucket**, so the central bucket never logs into itself. Set `enable_s3_access_logging = true` in `terraform/demo.auto.tfvars`, then:
```bash
terraform -chdir=terraform plan -out=s3log.tfplan
terraform -chdir=terraform apply s3log.tfplan
```
Expect about **6 to add** (the second bucket, its public-access block, encryption, expiry rule, policy, and the logging setting).

```bash
ACCESS_BUCKET=$(terraform -chdir=terraform output -raw s3_access_log_bucket)

# Touch the central bucket a few times so there is something to record
for i in 1 2 3; do aws s3 ls "s3://$BUCKET/alb/" --region "$AWS_REGION" > /dev/null; done

# Check for log files. Delivery is best effort and often takes an hour or more.
aws s3 ls "s3://$ACCESS_BUCKET/central-logs/" --region "$AWS_REGION" | tail -5
```
**S3 access logging does not check its permissions when it is created**, so a wrong policy fails silently and looks the same as "not delivered yet". Wait up to a few hours before concluding it is broken, and check the policy (see Troubleshooting).

**Verified in AWS (2026-10-31):** nothing appeared for the first 25 minutes, the first file arrived about **49 minutes** after the switch was turned on, and 72 files had arrived within about 2 hours. The records showed the engineer's calls, CloudTrail's and the ALB's writes, and the S3 console being browsed from the engineer's own IP (browser requests, including CORS `OPTIONS` preflight checks that show an anonymous requester). Don't be alarmed by anonymous `OPTIONS` records: check the source address and the user agent first.
Quick summary of who touched the bucket: download the files (`aws s3 sync "s3://$ACCESS_BUCKET/central-logs/" ./s3-access`) and count the requester, operation and key fields (fields 5, 7 and 8 of each space-separated line; the time is field 3 in brackets).

Each log line shows the requester, the operation (for example `REST.GET.OBJECT`), the key and the result. Read one with `aws s3 cp "s3://$ACCESS_BUCKET/central-logs/<file>" -`.

## Step 5: RDS logs to CloudWatch (optional)

RDS PostgreSQL logs can only be exported to CloudWatch Logs (writing them on to S3 is planned, not built). Set `enable_rds_logs = true` in `terraform/demo.auto.tfvars`, then:
```bash
terraform -chdir=terraform plan -out=rds.tfplan
terraform -chdir=terraform apply rds.tfplan
```
Expect about **2 to add** (two log groups with 14-day retention) and **1 to change** (the RDS instance's log exports, applied in place; I expect no reboot, but check the plan for `must be replaced` and stop if you see it).

```bash
# Exports are on
aws rds describe-db-instances --region "$AWS_REGION" --db-instance-identifier product-service-db --no-cli-pager \
  --query 'DBInstances[0].EnabledCloudwatchLogsExports' --output json

# The log groups exist with 14-day retention
aws logs describe-log-groups --region "$AWS_REGION" --log-group-name-prefix /aws/rds/instance/product-service-db \
  --query 'logGroups[].{name:logGroupName,retentionDays:retentionInDays}' --output table

# Read the recent database log
aws logs tail /aws/rds/instance/product-service-db/postgresql --region "$AWS_REGION" --since 1h --format short
```
A quiet database logs little with the default settings: expect checkpoint lines and the odd connection error, not queries. The first events can take a few minutes to appear.

**Verified in AWS (2026-10-31):** the apply took about 1.5 minutes, `EnabledCloudwatchLogsExports` showed both log types and `PendingModifiedValues` was empty (so it needed no reboot or maintenance window), both log groups had 14-day retention, and the PostgreSQL log showed a checkpoint every 5 minutes, including entries from before the change. The upgrade log had no streams, which is normal until an upgrade happens.

## Application logs (always on, no switch)

The service writes JSON lines to CloudWatch Logs `/ecs/product-service`. Field reference and filter examples are in [runbook.md](runbook.md#7-logs). Quick checks:
```bash
aws logs tail /ecs/product-service --region "$AWS_REGION" --since 15m --format short
aws logs tail /ecs/product-service --region "$AWS_REGION" --since 1h --filter-pattern '{ $.level = "error" }' --format short
```
**Database credential lines** (no value is ever logged): `Database credentials loaded from Secrets Manager` at start-up and after a refresh, and `Database login failed, retrying with the current secret` (a warning) when RDS has rotated the password and a new connection needed the fresh one. To see them: `aws logs tail /ecs/product-service --since 1h --filter-pattern '?"credentials loaded" ?"retrying with the current secret"'`. A task that logs the second line many times in a row, or `password authentication failed` errors with no retry, needs the checks in [Secrets.md](Secrets.md#debug).

**Match an app log line to an ALB log line:** the app's `request_id` is the `X-Amzn-Trace-Id` the ALB adds, and the ALB access log has the same value in its `trace_id` field (near the end of each line). To follow one request end to end, take the `X-Request-Id` response header,
then search both: the CloudWatch filter `{ $.request_id = "<id>" }`, and `grep "<id>"` over the downloaded ALB logs (Step 2).
**Status:** this structured logging was added after the first AWS test, tested locally (8 automated tests plus a run against a throwaway Postgres), then **deployed and verified in AWS**: JSON lines appeared in CloudWatch, the response header `X-Request-Id` was `Root=1-6ae66c27-...` (the ALB's trace ID), the same value was the `request_id` in the app log, and the ALB access log line for that request was found by searching for it (same request, same millisecond). During an 8-minute, 33,600-request load test the app logged **0 error-level lines** and no requests with status 400 or more.

## Step 6: Turn a log off

Set the switch back to `false` in `terraform/demo.auto.tfvars` and run `terraform -chdir=terraform apply`. This stops new logs and removes the trail, the second bucket or the log groups; files already written to the central bucket stay until they expire.

## Step 7: Tear down

```bash
terraform -chdir=terraform plan -destroy
terraform -chdir=terraform destroy
```
The buckets have `force_destroy = true`, so destroy also deletes the logs inside them, and it removes the CloudTrail trail. **Export anything you want to keep first** (for example `aws s3 sync "s3://$BUCKET" ./logs-backup`). CloudTrail's 90-day Event history in the console is not affected.

## Troubleshooting

| Symptom | Likely cause | What to do |
|---|---|---|
| `terraform apply` fails on the ALB with `Access Denied for bucket` | The bucket policy was not in place when the load balancer was updated | Re-run `apply`; the load balancer waits for the policy, so a repeat normally succeeds |
| No files under `alb/` after 10 minutes | No traffic reached the load balancer, or delivery is delayed | Send traffic (Step 2), wait, and check `describe-load-balancer-attributes` |
| `InsufficientS3BucketPolicyException` creating the trail | The CloudTrail statements are missing from the bucket policy | Confirm `enable_cloudtrail = true` was applied together with the policy (they are one plan) |
| `describe-trails` already shows a trail | The account has another trail, so a second would cost about $2 per 100,000 events | Don't enable `enable_cloudtrail` unless you accept that |
| `s3_access_log_bucket` output is empty or errors with `-raw` | The switch is off, so the bucket doesn't exist | Turn `enable_s3_access_logging` on and apply |
| No files in the access-log bucket after an hour | Delivery is best effort and can take hours, or the policy is wrong | Wait a few hours; then check the access-log bucket's policy allows `logging.s3.amazonaws.com` from the central bucket |
| A log you turned on stopped | A later `apply` without the switch set it back to `false` | Keep the switches in `terraform/demo.auto.tfvars` (Step 0) |
| `Error: No value for required variable` (`alb_ingress_cidr`) | `terraform/demo.auto.tfvars` is missing or doesn't set it | Recreate the file (Step 0), check `grep -c "enable_"` prints 3, and plan again |
| `Resource precondition failed ... opens the load balancer to the whole internet` | `alb_ingress_cidr` is `0.0.0.0/0` | Use your own address as a `/32`. Only set `allow_public_alb = true` if you truly want a public load balancer. |
| `AccessDenied` creating a bucket, trail or log group | The role lacks the permission | The error names the action; add it to your permission set |
| RDS log group has no retention | RDS created the log group itself before Terraform did | Apply with `enable_rds_logs = true` from a clean state, or set the retention by hand with `aws logs put-retention-policy` |

## Cost summary

| Item | Cost while on | If you forget to turn it off |
|---|---|---|
| ALB logs (always on) | cents a month (S3 storage) | no change |
| CloudTrail, first trail | free (management events), plus cents of S3 storage | about the same |
| S3 access logs | cents a month | about the same |
| RDS logs to CloudWatch | about $0.50 per GB, cents for a quiet database | grows only with database activity |

A test of a few hours costs well under a cent per log. The running stack itself (about $0.14 to $0.17 an hour) is the cost that matters: destroy it when you finish.
