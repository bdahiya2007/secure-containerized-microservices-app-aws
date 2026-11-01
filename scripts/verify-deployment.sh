#!/usr/bin/env bash
# Read-only verification of a deployed Product Service stack. It changes nothing in AWS: it reads
# configuration and sends a few harmless GET requests to the load balancer.
#
# Usage:   scripts/verify-deployment.sh [--skip-plan]
# Needs:   AWS CLI with a valid session, Terraform (outputs and the drift check), curl, python3.
#          Run it from anywhere; it works from the repository root. The drift check uses your settings in
#          terraform/demo.auto.tfvars (alb_ingress_cidr is required), so pass --skip-plan to leave it out.
# Exit:    0 if no check failed, 1 otherwise. SKIP means an optional log is switched off; WARN is advice.
set -u
cd "$(dirname "$0")/.." || exit 1

export AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT:-product-service}"
SKIP_PLAN=0
[ "${1:-}" = "--skip-plan" ] && SKIP_PLAN=1

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS  $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL  $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP  $1"; SKIP=$((SKIP + 1)); }
warn() { echo "WARN  $1"; }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name"; fi; }
retry() { local tries=$1 wait=$2; shift 2; local i; for ((i = 1; i <= tries; i++)); do "$@" && return 0; sleep "$wait"; done; return 1; }
tf_out() { terraform -chdir=terraform output -raw "$1" 2>/dev/null; }
py() { python3 -I -c "$1"; }

ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
if [ -z "$ACCOUNT" ]; then echo "FAIL  AWS session is not valid (try: aws sso login)"; exit 1; fi
ALB=$(tf_out alb_dns_name); LOG_BUCKET=$(tf_out log_bucket); ACCESS_BUCKET=$(tf_out s3_access_log_bucket)
RDS_HOST=$(tf_out rds_endpoint)
if [ -z "$ALB" ]; then echo "FAIL  no Terraform outputs found (is the stack applied, and are you in the right folder?)"; exit 1; fi
CLUSTER="$PROJECT-cluster"; SERVICE="$PROJECT"
# The target group that receives the traffic. With enable_blue_green, CodeDeploy alternates between "$PROJECT-tg" and
# "$PROJECT-tg-green", so ask the listener instead of assuming the first one.
LB_ARN=$(aws elbv2 describe-load-balancers --names "$PROJECT-alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
TG=$(aws elbv2 describe-listeners --load-balancer-arn "$LB_ARN" --query 'Listeners[0].DefaultActions[0].ForwardConfig.TargetGroups[?Weight>`0`].TargetGroupArn | [0]' --output text 2>/dev/null)
if [ -z "$TG" ] || [ "$TG" = None ]; then
  TG=$(aws elbv2 describe-target-groups --names "$PROJECT-tg" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
fi
LB_JSON=$(aws elbv2 describe-load-balancers --names "$PROJECT-alb" --query 'LoadBalancers[0]' --output json 2>/dev/null)
ALB_SG=$(echo "$LB_JSON" | py 'import json,sys; print(json.load(sys.stdin)["SecurityGroups"][0])')
VPC_ID=$(echo "$LB_JSON" | py 'import json,sys; print(json.load(sys.stdin)["VpcId"])')

# ---- check functions ----
no_drift() { terraform -chdir=terraform plan -no-color -input=false 2>&1 | grep -q '^No changes'; }
service_steady() {
  # ECS-controlled service: the deployment's rollout state. CodeDeploy-controlled service (enable_blue_green):
  # ECS reports no deployments, so use the primary task set's stability status instead.
  local d r s
  read -r d r s <<<"$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].[desiredCount,runningCount,deployments[0].rolloutState]' --output text)"
  if [ "$s" = None ]; then
    s=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query "services[0].taskSets[?status=='PRIMARY'].stabilityStatus | [0]" --output text)
    [ "$s" = STEADY_STATE ] && s=COMPLETED
  fi
  [ -n "$d" ] && [ "$d" = "$r" ] && [ "$s" = COMPLETED ]
}
targets_healthy_and_match() {
  local states running
  states=$(aws elbv2 describe-target-health --target-group-arn "$TG" --query 'TargetHealthDescriptions[].TargetHealth.State' --output text | tr '\t' '\n')
  running=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].runningCount' --output text)
  [ -n "$states" ] && [ "$(echo "$states" | wc -l)" = "$running" ] && ! echo "$states" | grep -qv '^healthy$'
}
http_code() { curl -s -m 10 -o /dev/null -w '%{http_code}' "$1"; }
health_ok() { [ "$(http_code "http://$ALB/health")" = 200 ] && curl -s -m 10 "http://$ALB/health" | grep -q '"ok"'; }
products_ok() { curl -s -m 10 "http://$ALB/products" | py 'import json,sys; d=json.load(sys.stdin); assert len(d)>=1 and all(isinstance(p["price"],(int,float)) for p in d)'; }
not_found_404() { [ "$(http_code "http://$ALB/nope")" = 404 ]; }
request_id_header() { curl -s -m 10 -D - -o /dev/null "http://$ALB/nope" | grep -qi '^x-request-id: '; }
alb_single_cidr() { aws ec2 describe-security-groups --group-ids "$ALB_SG" --query 'SecurityGroups[0].IpPermissions[].IpRanges[].CidrIp' --output text | tr '\t' '\n' | grep -qE '^[0-9.]+/32$'; }
alb_not_open() { ! aws ec2 describe-security-groups --group-ids "$ALB_SG" --query 'SecurityGroups[0].IpPermissions[].IpRanges[].CidrIp' --output text | grep -q '0\.0\.0\.0/0'; }
tasks_private() {
  local t eni
  for t in $(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --query taskArns --output text); do
    eni=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$t" --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value|[0]' --output text)
    [ "$(aws ec2 describe-network-interfaces --network-interface-ids "$eni" --query 'NetworkInterfaces[0].Association.PublicIp' --output text)" = None ] || return 1
  done
}
rds_json() { aws rds describe-db-instances --db-instance-identifier "$PROJECT-db" --query 'DBInstances[0]' --output json; }
rds_secure() { rds_json | py 'import json,sys; d=json.load(sys.stdin); assert d["DBInstanceStatus"]=="available" and d["StorageEncrypted"] and not d["PubliclyAccessible"] and d["Engine"]=="postgres"'; }
rds_exports() { rds_json | py 'import json,sys; d=json.load(sys.stdin); assert sorted(d.get("EnabledCloudwatchLogsExports") or [])==["postgresql","upgrade"]'; }
rds_exports_configured() { [ "$(rds_json | py 'import json,sys; print(len(json.load(sys.stdin).get("EnabledCloudwatchLogsExports") or []))')" -gt 0 ]; }
db_port_closed() { ! timeout 5 bash -c "</dev/tcp/$RDS_HOST/5432"; }
db_sg_locked() { aws ec2 describe-security-groups --filters "Name=group-name,Values=$PROJECT-db-*" --query 'SecurityGroups[0]' --output json | py 'import json,sys; d=json.load(sys.stdin); assert d["IpPermissionsEgress"]==[] and all(not p["IpRanges"] for p in d["IpPermissions"])'; }
app_sg_egress() { [ "$(aws ec2 describe-security-groups --filters "Name=group-name,Values=$PROJECT-app-*" --query 'SecurityGroups[0].IpPermissionsEgress[].FromPort' --output text | tr '\t' '\n' | sort | tr '\n' ' ')" = "443 5432 " ]; }
default_sg_empty() { aws ec2 describe-security-groups --filters "Name=group-name,Values=default" "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[0].[length(IpPermissions),length(IpPermissionsEgress)]' --output text | grep -q '^0.0$'; }
roles_conditions() { local r; for r in "$PROJECT-execution" "$PROJECT-task"; do aws iam get-role --role-name "$r" --query 'Role.AssumeRolePolicyDocument.Statement[0].Condition' --output json | grep -q 'aws:SourceAccount' || return 1; done; }
# The app reads the database secret itself (product-service/src/db-secret.js): the task role may do exactly that, on
# exactly that secret, and nothing else.
task_role_reads_only_db_secret() {
  [ "$(aws iam list-attached-role-policies --role-name "$PROJECT-task" --query 'length(AttachedPolicies)' --output text)" = 0 ] || return 1
  [ "$(aws iam list-role-policies --role-name "$PROJECT-task" --query 'length(PolicyNames)' --output text)" = 1 ] || return 1
  local name secret_arn
  name=$(aws iam list-role-policies --role-name "$PROJECT-task" --query 'PolicyNames[0]' --output text)
  secret_arn=$(tf_out db_secret_arn)
  [ -n "$secret_arn" ] || return 1
  aws iam get-role-policy --role-name "$PROJECT-task" --policy-name "$name" --query PolicyDocument --output json \
    | SECRET_ARN="$secret_arn" py 'import json,os,sys; d=json.load(sys.stdin); s=d["Statement"]; assert len(s)==1 and s[0]["Effect"]=="Allow" and s[0]["Action"]==["secretsmanager:GetSecretValue"] and s[0]["Resource"]==os.environ["SECRET_ARN"]'
}
# The task definition the service is running holds no credential: no "secrets" injection, no DB_USER or DB_PASSWORD variable,
# and only the NAME (ARN) of the secret in DB_SECRET_ARN.
running_task_definition() {
  local td
  td=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].deployments[0].taskDefinition' --output text)
  if [ -z "$td" ] || [ "$td" = None ]; then
    td=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query "services[0].taskSets[?status=='PRIMARY'].taskDefinition | [0]" --output text)
  fi
  echo "$td"
}
task_definition_has_no_credentials() {
  local td; td=$(running_task_definition)
  [ -n "$td" ] && [ "$td" != None ] || return 1
  aws ecs describe-task-definition --task-definition "$td" --query 'taskDefinition.containerDefinitions[0].{env:environment[].name,secrets:secrets}' --output json \
    | py 'import json,sys; d=json.load(sys.stdin); env=d["env"] or []; assert not d["secrets"] and "DB_SECRET_ARN" in env and "DB_PASSWORD" not in env and "DB_USER" not in env'
}
# The execution role (ECS's own identity for starting a task) cannot read the database secret: only the task role can.
execution_role_secret_access() { [ "$(aws iam list-role-policies --role-name "$PROJECT-execution" --query 'length(PolicyNames)' --output text)" = 0 ]; }
scaling_configured() {
  aws application-autoscaling describe-scalable-targets --service-namespace ecs --resource-ids "service/$CLUSTER/$SERVICE" --query 'ScalableTargets[0].[MinCapacity,MaxCapacity]' --output text | grep -qE '^[0-9]+[[:space:]]+[0-9]+$' \
    && [ "$(aws application-autoscaling describe-scaling-policies --service-namespace ecs --resource-id "service/$CLUSTER/$SERVICE" --query 'length(ScalingPolicies)' --output text)" -ge 1 ]
}
dashboard_ok() { aws cloudwatch get-dashboard --dashboard-name "$PROJECT" --query DashboardBody --output text | py 'import json,sys; d=json.load(sys.stdin); assert sum(1 for w in d["widgets"] if w["type"]=="metric")>=1'; }
log_group_retention() { [ "$(aws logs describe-log-groups --log-group-name-prefix "/ecs/$PROJECT" --query 'logGroups[0].retentionInDays' --output text)" != None ]; }
json_app_logs() {
  aws logs filter-log-events --log-group-name "/ecs/$PROJECT" --start-time "$(( $(date +%s) - 10800 ))000" --filter-pattern '{ $.msg = "request" }' --no-paginate --output json \
    | py 'import json,sys; ev=json.load(sys.stdin)["events"]; assert ev; d=json.loads(ev[-1]["message"]); assert d["request_id"] and isinstance(d["status"],int) and "duration_ms" in d'
}
alb_logs_today() { [ "$(aws s3 ls "s3://$LOG_BUCKET/alb/" --recursive | grep -c "$(date -u +%Y/%m/%d)")" -gt 0 ]; }
trail_exists() { [ "$(aws cloudtrail describe-trails --trail-name-list "$PROJECT-trail" --query 'trailList[0].Name' --output text 2>/dev/null)" != None ]; }
trail_logging() { aws cloudtrail get-trail-status --name "$PROJECT-trail" --query '[IsLogging,LatestDeliveryError]' --output text | grep -q '^True'; }
s3_access_logs() { [ "$(aws s3 ls "s3://$ACCESS_BUCKET/central-logs/" | wc -l)" -gt 0 ]; }
log_bucket_secure() {
  aws s3api get-public-access-block --bucket "$LOG_BUCKET" --query PublicAccessBlockConfiguration --output json | grep -vq false \
    && [ "$(aws s3api get-bucket-encryption --bucket "$LOG_BUCKET" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' --output text)" = AES256 ] \
    && aws s3api get-bucket-policy --bucket "$LOG_BUCKET" --query Policy --output text | grep -q DenyInsecureTransport
}
ecr_ok() { [ "$(aws ecr describe-repositories --repository-names "$PROJECT" --query 'repositories[0].imageScanningConfiguration.scanOnPush' --output text)" = True ] && [ "$(aws ecr describe-images --repository-name "$PROJECT" --query 'length(imageDetails)' --output text)" -gt 0 ]; }

# Fargate, not EC2: the service and every running task use the FARGATE launch type, the task definition is Fargate-only
# with awsvpc networking, and the cluster owns no EC2 capacity (no container instances, no capacity providers).
fargate_launch_type() {
  [ "$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].launchType' --output text)" = FARGATE ] || return 1
  local tasks t
  tasks=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --query taskArns --output text)
  [ -n "$tasks" ] || return 1
  for t in $tasks; do
    [ "$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$t" --query 'tasks[0].launchType' --output text)" = FARGATE ] || return 1
  done
}
fargate_task_definition() {
  aws ecs describe-task-definition --task-definition "$SERVICE" --query 'taskDefinition.[requiresCompatibilities,networkMode,executionRoleArn]' --output json \
    | py 'import json,sys; c,n,r=json.load(sys.stdin); assert c==["FARGATE"] and n=="awsvpc" and r'
}
no_ec2_capacity() {
  aws ecs describe-clusters --clusters "$CLUSTER" --query 'clusters[0].[registeredContainerInstancesCount,length(capacityProviders)]' --output text | grep -q '^0[[:space:]]0$'
}

echo "Verifying $PROJECT in $AWS_REGION (read-only)"
echo "--- drift and service"
if [ "$SKIP_PLAN" = 1 ]; then skip "Terraform drift check (--skip-plan)"; else check "Terraform plan shows no changes (no drift)" no_drift; fi
retry 6 15 service_steady && pass "ECS desired = running and the rollout is complete" || fail "ECS desired = running and the rollout is complete"
retry 6 15 targets_healthy_and_match && pass "All load balancer targets are healthy and match the running tasks" || fail "All load balancer targets are healthy and match the running tasks"

echo "--- endpoints through the load balancer"
check "GET /health returns 200 with status ok" health_ok
check "GET /products returns 200, a JSON array, numeric prices" products_ok
check "GET /nope returns 404" not_found_404
check "X-Request-Id header is returned" request_id_header

echo "--- network and data security"
check "ALB accepts port 80 only from a single /32" alb_single_cidr
check "ALB is not open to 0.0.0.0/0" alb_not_open
check "Tasks have no public IP" tasks_private
check "RDS is available, PostgreSQL, encrypted, not public" rds_secure
check "Database port 5432 is NOT reachable from this machine" db_port_closed
check "db security group: no outbound rules, inbound only from security groups" db_sg_locked
check "app security group: outbound only TCP 443 and 5432" app_sg_egress
check "VPC default security group is empty" default_sg_empty

echo "--- IAM least privilege"
check "Both ECS roles have the confused-deputy conditions" roles_conditions
check "Task role can only read the one database secret (GetSecretValue on that ARN, nothing else)" task_role_reads_only_db_secret
check "The running task definition holds no credentials (no secrets block, no DB_USER or DB_PASSWORD, only DB_SECRET_ARN)" task_definition_has_no_credentials
check "Execution role has no permission to read the database secret (only the task role can)" execution_role_secret_access

echo "--- Fargate (no EC2)"
check "Service and every running task use the FARGATE launch type" fargate_launch_type
check "Task definition is Fargate-only with awsvpc networking and an execution role" fargate_task_definition
check "Cluster has no EC2 container instances and no capacity providers" no_ec2_capacity

echo "--- scaling, monitoring and registry"
check "Auto Scaling target and policies exist" scaling_configured
check "CloudWatch dashboard exists with charts" dashboard_ok
check "App log group has a retention period" log_group_retention
check "ECR repository scans on push and holds an image" ecr_ok

echo "--- logging"
retry 4 10 json_app_logs && pass "Recent app log lines are JSON with request_id, status and duration" || fail "Recent app log lines are JSON with request_id, status and duration (send some requests first: successful /health checks are not logged)"
check "ALB access logs were delivered today" alb_logs_today
check "Central log bucket: public access blocked, SSE-S3, TLS-only" log_bucket_secure
if trail_exists; then check "CloudTrail is logging with no delivery error" trail_logging; else skip "CloudTrail (enable_cloudtrail is off)"; fi
if [ -n "$ACCESS_BUCKET" ]; then check "S3 server access logs were delivered (can take an hour or more)" s3_access_logs; else skip "S3 access logs (enable_s3_access_logging is off)"; fi
if rds_exports_configured; then check "RDS log exports are on (postgresql, upgrade)" rds_exports; else skip "RDS log exports (enable_rds_logs is off)"; fi
if [ "$(aws budgets describe-budgets --account-id "$ACCOUNT" --query 'length(Budgets)' --output text 2>/dev/null || echo 0)" = 0 ]; then warn "No AWS budget alert found; set one so a forgotten stack can't run up a bill"; else pass "An AWS budget alert exists"; fi

echo
echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = 0 ]
