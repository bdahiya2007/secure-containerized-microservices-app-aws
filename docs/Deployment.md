# Deployment guide: commands, verification and debugging

How to deploy the Product Service, check that it works, and find out what is wrong when it does not. For the design behind the pipeline see [CICD.md](CICD.md); for the first-time build from scratch see [runbook.md](runbook.md).

There are two kinds of change, and they deploy differently:

| What changed | How it is deployed | Who runs it |
|---|---|---|
| **Application** (`product-service/**`, `appspec.yaml`, `deploy.yml`) | Merge to `main`; GitHub Actions builds, pushes and runs a CodeDeploy blue/green deployment | The pipeline |
| **Infrastructure** (`terraform/**`) | `terraform plan`, review, `terraform apply` | You, by hand |

Replace `<ACCOUNT_ID>` with your AWS account ID wherever it appears. Never commit it.

## 0. Variables

```bash
export AWS_REGION=us-east-1
export PROJECT=product-service
export CLUSTER=product-service-cluster
export SERVICE=product-service
export GH_REPO=bdahiya2007/secure-containerized-microservices-app-aws
aws sso login        # when the session has expired
```

## 1. One-time setup (pipeline)

Done once per AWS account and repository. Full explanation and the security reasoning are in [CICD.md](CICD.md#one-time-setup).

| Step | Command | Expected result |
|---|---|---|
| Pin the OIDC trust to this repository | `gh api -X PUT repos/$GH_REPO/actions/oidc/customization/sub -F use_default=true -F use_immutable_subject=true` then `gh api repos/$GH_REPO/actions/oidc/customization/sub --jq .sub_claim_prefix` | Prints `repo:<owner>@<id>/<repo>@<id>` |
| Create the deploy role | `cd terraform/bootstrap && terraform init && terraform apply -var 'github_sub_prefix=<value from above>'` | 2 added (role and policy) |
| Store the role ARN | `printf '%s' "$(terraform output -raw deploy_role_arn)" \| gh secret set AWS_DEPLOY_ROLE_ARN -R $GH_REPO` | Secret appears in `gh secret list -R $GH_REPO` |
| Switch the service to blue/green | `cd terraform && terraform apply -var enable_blue_green=true` (or set it in `demo.auto.tfvars`) | Service replaced, **a short outage**; see section 6 if the first apply stops |
| Use remote state | `terraform init -backend-config=backend.hcl -migrate-state` | State object in the S3 bucket |

Pass the secret with `printf` from the Terraform output. Pasting into the `gh secret set` prompt once produced an empty secret.

## 2. Deploy the application (the normal path)

1. Change code under `product-service/`, open a pull request, wait for the six checks, merge.
2. The `Deploy` workflow starts on its own. To start it by hand (for example to redeploy the same code):
   ```bash
   gh workflow run deploy.yml -R $GH_REPO
   gh run watch -R $GH_REPO          # pick the run; Ctrl+C stops watching, not the deployment
   ```
3. What the workflow does, in order: unit tests; OIDC login; check the CodeDeploy group exists; ECR login; build and push the image tagged with the commit SHA; wait for the ECR scan and stop on CRITICAL findings; register a new task definition revision; start the CodeDeploy deployment; wait for it to succeed.
4. Expect about 16 minutes: traffic moves 10% per minute (about 10 minutes), then the old tasks stay for 5 minutes.

Only one deployment runs at a time. A second push queues behind the first and starts when it ends.

### Watch the deployment

```bash
# latest deployment and its status
D=$(aws deploy list-deployments --application-name $PROJECT --deployment-group-name $PROJECT-dg \
      --query 'deployments[0]' --output text)
aws deploy get-deployment --deployment-id $D --query 'deploymentInfo.[status,errorInformation]' --output json

# traffic split between the two target groups (weights change every minute)
aws elbv2 describe-listeners \
  --load-balancer-arn $(aws elbv2 describe-load-balancers --names $PROJECT-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text) \
  --query 'Listeners[0].DefaultActions[0].ForwardConfig.TargetGroups[].[TargetGroupArn,Weight]' --output text

# the two task sets (PRIMARY = current, ACTIVE = being shifted to, DRAINING = being removed)
aws ecs describe-services --cluster $CLUSTER --services $SERVICE \
  --query 'services[0].[runningCount,taskSets[].[status,stabilityStatus,runningCount]]' --output text
```

In the console: CodeDeploy, Deployments, the latest one shows a traffic shifting progress bar. EC2, Load Balancers, `product-service-alb`, Listeners and rules, the HTTPS:443 listener shows the weights (HTTP:80 only redirects).

`blue` is `product-service-tg` and `green` is `product-service-tg-green`. They swap roles on every deployment.

### What is normal during a deployment

- 4 tasks running for a desired count of 2: the old and new tasks overlap.
- `verify-deployment.sh` reports failures for the rollout and target-health checks. Run it after the deployment ends.
- The GitHub job sits on `Wait for the deployment`. Its log appears only when the job ends.

## 3. Deploy infrastructure (Terraform)

```bash
cd terraform
git checkout main && git pull
terraform init -backend-config=backend.hcl      # first time, or after a provider change
terraform plan -out=tfplan                      # read it: what is added, changed, destroyed
terraform apply tfplan                          # applies exactly that plan
```

- Stop if the plan destroys anything you did not expect. Replacing `aws_ecs_service` is expected only when `enable_blue_green` changes.
- A Terraform-only change does not start the pipeline.
- Terraform cannot validate everything. `terraform validate` accepts a dashboard body that CloudWatch then rejects, so check the apply output.

## 3a. If your IP address changes

The load balancer accepts ports 443 and 80 (80 only redirects to HTTPS) only from the address in `alb_ingress_cidr` (your own public IP as a `/32`), so when your internet address changes (a new network, a router restart, a home ISP rotating addresses) **you are locked out of your own demo**, while the application keeps running normally for everyone else who is allowed.

**Symptoms:** `curl` to the load balancer hangs and times out, a browser spins, and `scripts/verify-deployment.sh` fails its endpoint checks. Nothing is wrong with the service itself (check with `aws ecs describe-services`).

**Fix:**
1. Find your new address: `curl -s https://checkip.amazonaws.com`
2. Put it in the **git-ignored** file `terraform/demo.auto.tfvars` (never in a tracked file):
   ```hcl
   alb_ingress_cidr = "<your new address>/32"
   ```
3. Review and apply (expect **1 to change**: the load balancer's security group rule, updated in place; no restart and no downtime):
   ```bash
   cd terraform
   terraform plan
   terraform apply
   ```
4. Update the private block list so the secret scanner protects the new address too (and, if you like, remove the old one): `~/.config/secret-scan/literals`, one value per line. That file is local only and readable only by you.
5. Check: `curl -s -o /dev/null -w "%{http_code}\n" http://<load balancer DNS name>/health` returns 200.

**Do not** paste your address into the README, the docs, a pull request, an issue or a commit message; use a placeholder such as `<your address>/32`. The scanner blocks the address in commits only if it is on the private block list.

**Do not** edit the security group by hand in the console or with the AWS CLI as a permanent fix: Terraform would show it as drift and change it back on the next apply. A one-off CLI edit is fine to get back in quickly, as long as you then make the same change in `demo.auto.tfvars` and apply.

If you must reach the service from several places or from a network whose address keeps changing, the options are a wider CIDR you trust (such as your office or VPN range), or opening the load balancer to the internet with `allow_public_alb = true`. The second is a real security decision, because the API has no authentication yet (see the README's known limitations).

## 4. Verify

> **With disaster recovery on**, Region B is a separate stack (`terraform/region-b`) that this script does not check. After the main stack is verified, check Region B directly (`curl https://<usw2 name>/health` and `/products` answer 200) and see [DR_Runbook.md](DR_Runbook.md) for the drills and the whole deploy-test-drill-destroy order (section 7).

### Automated: 35 read-only checks

```bash
./scripts/verify-deployment.sh              # includes a terraform plan (drift check)
./scripts/verify-deployment.sh --skip-plan  # faster; skips the drift check
```

It takes a couple of minutes. Expect `34 passed, 0 failed, 1 skipped` with `--skip-plan` and Spot on (the skipped one is the drift check; with Spot off it is `33 passed, 0 failed, 2 skipped`, because the Fargate Spot check is skipped too). With HTTPS on, the endpoint checks run against the HTTPS name (`app_url`). Run it when no deployment is in progress.

### By hand

```bash
# app_url is https://<your name> with enable_https, otherwise the load balancer's own http:// address
URL=$(terraform -chdir=terraform output -raw app_url)
curl -s -o /dev/null -w "health   %{http_code}\n" $URL/health      # 200
curl -s $URL/products | head -c 300; echo                           # JSON array of 3 products
curl -s -o /dev/null -w "missing  %{http_code}\n" $URL/nope        # 404

# which image is running
aws ecs describe-task-definition --task-definition $PROJECT \
  --query 'taskDefinition.containerDefinitions[0].image' --output text    # ...:product-service:<commit SHA>

# targets healthy in the live target group, and tasks match
aws ecs describe-services --cluster $CLUSTER --services $SERVICE --query 'services[0].[desiredCount,runningCount]' --output text

# Terraform matches AWS
terraform -chdir=terraform plan                                             # "No changes"
```

The load balancer accepts ports 443 and 80 (80 only redirects to HTTPS) only from the address in `alb_ingress_cidr`. If `curl` hangs, your public IP has probably changed (see section 6).

## 5. Roll back

| Situation | What to do |
|---|---|
| The new tasks never become healthy | **Users are protected:** traffic stays on the old tasks (tested: no failed request). But CodeDeploy does **not** fail the deployment quickly: it kept retrying for over 30 minutes in the test, and the workflow stays running. Stop it: `aws deploy stop-deployment --deployment-id <id> --auto-rollback-enabled`; the broken tasks are removed in about 35 seconds. Read the cause in the ECS service events and the app log (section 6) |
| A bad release got through while traffic is shifting or in the 5-minute wait | `aws deploy stop-deployment --deployment-id <id> --auto-rollback-enabled`; or stop it in the CodeDeploy console |
| A bad release is fully live | Revert the commit through a pull request. The pipeline deploys the reverted code (about 16 minutes). To redeploy an older commit right away, run the workflow from a branch that has it |
| The deployment group or service is broken | `terraform apply -var enable_blue_green=false` returns to rolling updates (replaces the service, short outage) |

The rollback was tested on 2026-11-02 with a deliberately broken release ([Rollback_Test.md](Rollback_Test.md)): users were not affected and the rollback took about 35 seconds. Note that CodeDeploy does not fail a crashing release by itself quickly (still `InProgress` after 30 minutes), so you may need to stop it yourself with `stop-deployment` (see the table above).

## 6. Debug

Start with where it failed, then read the matching row.

```bash
gh run list -R $GH_REPO --limit 5
gh run view <run-id> -R $GH_REPO --json jobs --jq '.jobs[]|{name,conclusion,failed:[.steps[]|select(.conclusion=="failure")|.name]}'
gh run view <run-id> -R $GH_REPO --log-failed        # the log of the failed step (after the job has ended)
```

### Pipeline failures

| Where | Message or symptom | Cause | Fix |
|---|---|---|---|
| Configure AWS credentials | `Credentials could not be loaded` | `AWS_DEPLOY_ROLE_ARN` is empty or missing | `gh secret list -R $GH_REPO`; set it with `printf '%s' "$ARN" \| gh secret set AWS_DEPLOY_ROLE_ARN -R $GH_REPO` |
| Configure AWS credentials | `Not authorized to perform sts:AssumeRoleWithWebIdentity` | Trust policy mismatch: wrong repo ID, the job is not in the `dev` environment, or the OIDC provider is missing | Re-read the subject prefix and re-apply `terraform/bootstrap`; check `environment: dev` in the workflow; the IAM OIDC provider for `token.actions.githubusercontent.com` must exist |
| Check the CodeDeploy group | `CodeDeploy deployment group not found` | The stack was not applied with `enable_blue_green = true` | Apply it (section 1) |
| Build and push the image | `denied` or `no basic auth credentials` | ECR login step failed, or the role lacks an `ecr:` action | Read the line above the error; add only the missing action to `terraform/bootstrap` |
| Wait for the ECR scan | `ScanNotFoundException` | Old workflow using `aws ecr wait`, which fails before the scan is recorded | Fixed: the step polls for up to 5 minutes. Make sure `main` has the polling version |
| Wait for the ECR scan | `The image has N CRITICAL vulnerabilities` | A real finding | `aws ecr describe-image-scan-findings --repository-name $PROJECT --image-id imageTag=<sha>`; update the base image or dependency |
| Register task definition | `AccessDenied` on `iam:PassRole` | A task definition names a role the deploy role may not pass | Only `product-service-execution` and `product-service-task` are allowed |
| Start the deployment | `AccessDenied` on a `codedeploy:` action | A permission is missing from the deploy role | Add the single action in `terraform/bootstrap/main.tf`, apply by hand |
| Wait for the deployment | Job red, status `Failed` | The new tasks failed the health check, or crashed | Section 6, "A deployment failed" |

### A deployment failed

```bash
D=<deployment id>
aws deploy get-deployment --deployment-id $D --query 'deploymentInfo.{status:status,error:errorInformation,rollback:rollbackInfo}' --output json
aws deploy list-deployment-targets --deployment-id $D                  # per-target detail
aws ecs list-tasks --cluster $CLUSTER --service-name $SERVICE --desired-status STOPPED   # recently stopped tasks
aws ecs describe-tasks --cluster $CLUSTER --tasks <task-arn> --query 'tasks[0].[stoppedReason,containers[0].reason,containers[0].exitCode]' --output text
aws logs tail /ecs/$PROJECT --since 30m                                # application logs (JSON lines)
```

Common causes: the app cannot reach the database (check `DB_*` settings and security groups), the container exits at start (exit code in `describe-tasks`), `/health` does not return 200, or the image cannot be pulled (ECR permissions or NAT).

### Terraform and AWS

| Symptom | Cause | Fix |
|---|---|---|
| `Unable to Start a service that is still Draining` on `apply` | ECS keeps a deleted service in `DRAINING`, so the same name cannot be reused yet | Wait until `aws ecs describe-services ... --query 'services[0].status'` says `INACTIVE`, then re-run the same apply |
| `AccessDenied` on `iam:CreateRole`, `AttachRolePolicy` or `PassRole` | The SSO permission set lacks the scoped policy, or it is out of date | Update it from [iam/product-service-iam-policy.json](iam/product-service-iam-policy.json) and run `aws sso login` |
| `InvalidParameterInput ... dashboard body is invalid` | The dashboard JSON has the wrong shape (for example `flatten()` on nested rows) | Fix `monitoring.tf`; check the planned JSON before applying |
| `Error acquiring the state lock` | Another run holds the lock, or an earlier run was interrupted | Wait; if you are sure nothing else is running, `terraform force-unlock <id>` |
| `Backend initialization required` | Not initialised with the backend config | `terraform init -backend-config=backend.hcl` |
| `update-service --force-new-deployment` fails | Not supported when CodeDeploy controls the service | To restart tasks, stop them (`aws ecs stop-task`, ECS replaces them) or run the Deploy workflow |
| `curl` to the ALB hangs | Your public IP changed; the load balancer allows only `alb_ingress_cidr` (steps in [section 3a](#3a-if-your-ip-address-changes)) | Update `alb_ingress_cidr` in `demo.auto.tfvars` and apply |
| `/products` returns 500 with `password authentication failed`, or `/health` is 503 with `AccessDeniedException` for `GetSecretValue` | The database password was rotated (the app retries once with a fresh copy), or the task role cannot read the secret | See [Secrets.md](Secrets.md#debug); check `aws iam get-role-policy --role-name product-service-task --policy-name read-db-secret` |
| The service is healthy (tasks running, targets healthy) but every request returns 503 | The load balancer listener points at the empty target group: a CodeDeploy deployment leaves it on blue or green, and a service created by Terraform always uses blue | `aws elbv2 describe-listeners` and `describe-target-health` to confirm, then `aws elbv2 modify-listener --listener-arn <listener> --default-actions Type=forward,TargetGroupArn=<the group with healthy targets>`; see [Fargate_Spot.md](Fargate_Spot.md#test-2-fargate_base--2-the-zone-fix) |
| `CannotPullContainerError ... failed to resolve ref` on a recreated service | The `:latest` image tag does not exist in ECR (the deploy workflow keeps it up to date) | `aws ecr describe-images --repository-name product-service --image-ids imageTag=latest`; if missing, re-tag the newest image with `aws ecr put-image` |
| Dashboard or scaling shows nothing for requests | Looking at the idle target group | Both groups are charted; see [CICD.md](CICD.md#two-target-groups-what-it-changes) |

### Useful logs and metrics

```bash
aws logs tail /ecs/$PROJECT --follow                                   # application logs
aws logs tail /ecs/$PROJECT --since 1h --filter-pattern '{ $.level = "error" }'
aws ecs describe-services --cluster $CLUSTER --services $SERVICE --query 'services[0].events[:8].[createdAt,message]' --output text
aws cloudwatch get-dashboard --dashboard-name $PROJECT --query DashboardBody --output text | head -c 300
```

The dashboard is in the Terraform output `dashboard_url`. More on logging in [Logging_Runbook.md](Logging_Runbook.md).

## 7. Tear down

> **With disaster recovery on**, destroy the Region B stack (`terraform -chdir=terraform/region-b destroy`) **before** the main stack, fail back first if Region B is the database writer, delete the failover snapshot, and check both Regions for leftovers: [DR_Runbook.md](DR_Runbook.md), section 5.

Costs roughly $0.16 to $0.20 an hour while running (NAT gateway, ALB, RDS, Fargate).

```bash
terraform -chdir=terraform plan -destroy        # read it
terraform -chdir=terraform destroy
terraform -chdir=terraform/bootstrap destroy    # the deploy role
```

The destroy takes about 10 to 15 minutes (RDS about 7). Use a saved plan (`plan -destroy -out=destroy.tfplan`, then `apply destroy.tfplan`) so exactly what you reviewed is deleted, and delete that file afterwards (it holds your address and account details). The destroy removes your DNS record and certificate for the app name but only *reads* the hosted zone, so your other records stay. If it stops with `ResourceInUse` on the green target group (CodeDeploy points the listener at it and Terraform cannot see that; found on 2026-11-02, since fixed by making the listeners depend on it), plan and apply the destroy again: it continues where it stopped.

Check afterwards that no NAT gateway, load balancer or RDS instance is left, and delete the images in ECR and the log buckets if they are not removed. The state object stays in the shared bucket. Details in [runbook.md](runbook.md#10-tear-down).
