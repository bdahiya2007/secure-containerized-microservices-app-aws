# FAQ

Questions about the design, the behaviour and the operation of this project, grouped by topic, with short answers and where to read more.
Everything described here was built and checked in AWS (`us-east-1`, with `us-west-2` for disaster recovery) unless an answer says "not
tested", which means exactly that. The stack is destroyed between sessions, so "applied" and "drilled" refer to the dated sessions in the
test records.

**Topics:** [Design](#design) | [The service and its API](#the-service-and-its-api) | [Security](#security) | [Secrets and the database](#secrets-and-the-database) | [Security testing](#security-testing) | [CI/CD and releases](#cicd-and-releases) | [Scaling](#scaling) | [HTTPS and DNS](#https-and-dns) | [Disaster recovery](#disaster-recovery) | [Cost](#cost) | [Terraform and state](#terraform-and-state) | [Operating and troubleshooting](#operating-and-troubleshooting)

---

## Design

### What does this project build?
A small Node.js Product Service running as containers on **ECS Fargate** behind an **Application Load Balancer**, with a private PostgreSQL
database, the image in **ECR**, the credentials in **Secrets Manager**, releases by **CodeDeploy blue/green** from **GitHub Actions**, and all of
it defined in **Terraform**. An optional second Region adds disaster recovery. The picture is in [Architecture.md](Architecture.md#1-end-to-end-architecture).

### Why Terraform, and not CloudFormation or CDK?
Terraform was the requirement from the start, so everything (network, database, ECS, CodeDeploy, IAM, the rotation function, Route 53 failover)
is Terraform, and there is no CloudFormation. The design does not depend on the tool.

### Why Fargate and not EC2?
No servers to patch or scale, a task is the unit of isolation, and the cost for a demo is small. The trade-offs and a comparison table are in
[EC2_vs_Fargate.md](EC2_vs_Fargate.md); Fargate Spot for the tasks above the base two is in [Fargate_Spot.md](Fargate_Spot.md).

### Why are the tasks in private subnets with a NAT gateway?
So nothing in the stack except the load balancer has a public address. Tasks reach ECR, Secrets Manager and CloudWatch through the NAT gateway
(and S3 through a free gateway endpoint). One NAT gateway keeps the demo cheap; it is a single point of failure for outbound traffic, listed as a gap.

### Which parts are optional?
Four Terraform switches, all off by default: `enable_https` (a domain and certificate), `enable_aurora` (Aurora Serverless v2 instead of the RDS
instance, with a self-managed rotating secret), `enable_dr_replica` (replication to Region B) and `enable_dr_failover` (Route 53 failover). With all
four on and the Region B stack applied, this is the design that was drilled on 2026-11-07.

## The service and its API

### What does the service do?
Three routes: `GET /health` (200 when the database answers `SELECT 1`, 503 otherwise), `GET /products` (a JSON array of products) and `GET /`
(a small JSON description with no version or infrastructure detail). Anything else returns 404. There are no write routes.

### Why does `/products` return 500?
The `products` table does not exist yet. Load the schema with the one-off migration task (`terraform/migrate.tf`, started with
`aws ecs run-task`; no `psql` or bastion needed): [runbook.md](runbook.md#2-load-the-database-schema).

### Why does the load balancer refuse my request or time out?
The load balancer admits only `alb_ingress_cidr`, your own address as a `/32`. If your public address changed, update it and apply:
[Deployment.md](Deployment.md#3a-if-your-ip-address-changes).

### Why is there no authentication?
It is a demo with read-only sample data, and the access control is the address restriction. It is the top open gap
([THREAT_MODEL.md](THREAT_MODEL.md), T1). Before any public exposure it needs an authorizer (Cognito or JWT) and a WAF.

### Can I open it to the internet?
Only deliberately: `alb_ingress_cidr = "0.0.0.0/0"` is refused unless `allow_public_alb = true`. There is no default for `alb_ingress_cidr`, because
a default once opened the load balancer by mistake ([E2E_Test_Results.md](E2E_Test_Results.md)). Public only during demos is the working rule.

## Security

### What protects the service?
Layers, each assuming the one before can fail: an address-restricted load balancer, TLS 1.3, tasks in private subnets with chained security
groups (internet to ALB to app to database), a non-root container with a read-only filesystem, a task role that can read one secret, an encrypted
private database, and confused-deputy conditions on the ECS roles. The full list is in [Architecture.md](Architecture.md#5-defense-in-depth) and
the threats and residual risk are in [THREAT_MODEL.md](THREAT_MODEL.md).

### What can each role do?
- **Task role** (the app): `secretsmanager:GetSecretValue` on the one database secret (with Aurora also `kms:Decrypt` on its key, through Secrets Manager only).
- **Execution role** (ECS starting the task): the AWS-managed ECS execution policy; it cannot read the database secret.
- **Rotation function role** (Aurora only): one secret, one cluster, its own log group.
- **Deploy role** (GitHub Actions): push to one ECR repository, register task definitions, pass the two ECS roles, run the CodeDeploy deployment. It cannot apply Terraform.

### Why did the first `apply` fail with `AccessDenied` on `iam:CreateRole`?
The PowerUserAccess permission set excludes IAM, so it cannot create the ECS roles. Add the scoped policy in
[iam/product-service-iam-policy.json](iam/product-service-iam-policy.json) (roles named `product-service-*` only) to the permission set, then log in again.

### Does the database connection verify the certificate?
No. The app encrypts the connection but `rejectUnauthorized` defaults to false, so the RDS certificate is not checked. Someone with a network
position inside the VPC could in theory impersonate the database. The planned fix is to bundle the AWS RDS CA and turn verification on (a
known gap in the README).

### Why are the ECR tags mutable?
The pipeline pushes unique commit-SHA tags, but the Terraform task definition still starts from `latest`, so the repository cannot be made
immutable until that changes. It is listed as a gap (T10).

### Is there a WAF, GuardDuty, Security Hub or Inspector?
Not in this project's Terraform. The protections are preventive (private subnets, scoped IAM, encryption, TLS) plus scanning in CI. AWS-native
scanners are a roadmap item: [Application_Security_Testing.md](Application_Security_Testing.md#frameworks-and-standards-behind-the-scans).

## Secrets and the database

### Where is the database password?
In Secrets Manager. It is never in code, variables, the image, the task definition, the environment or Terraform state. The app reads it itself at
runtime with its task role and fetches it again after a rotation ([Secrets.md](Secrets.md)). With the default RDS instance, RDS generates and
rotates it. With Aurora the secret is self-managed: a write-only password, rotated every 7 days by a small Lambda function that calls
`ModifyDBCluster` and never logs in to the database.

### Why is there a rotation Lambda when RDS can rotate its own password?
Aurora Global Database does not support Secrets Manager's managed credentials, so the password is generated in Terraform as a write-only value
and rotated by the function in `lambdas/db-rotation` ([DR_Design_Decisions.md](DR_Design_Decisions.md)).

### Has rotation been tested?
Yes, manually: under load (100 of 100 parallel requests succeeded after a retry race was fixed), during a blue/green deployment, and on Aurora
(104 s end to end with no failed request, after the first run found and fixed a retry livelock). **The scheduled 7-day rotation has never run.**

### How do I tell which database is in use?
With `enable_aurora` off, an RDS PostgreSQL instance (`db.t4g.micro`, single-AZ). With it on, an Aurora Serverless v2 cluster (0.5 to 4 ACU).
`scripts/verify-deployment.sh` checks whichever is deployed.

### Is the data kept if I destroy the stack?
No. The database is deleted with its data (no final snapshot), and the ECR repository with its images. The sample data is reloaded by the
migration task. A failover can leave an `rds:unplanned-global-failover-...` snapshot behind; the runbook says to check for it (after the last
teardown none was found).

## Security testing

### How is the application security tested, and what did it find?
Semgrep and CodeQL (code), `npm audit`, Dependabot and Trivy (dependencies), Trivy and ECR scan-on-push (the image), Checkov and Trivy (Terraform),
and a secret scanner, plus unit tests and live load, rollback, rotation and failover tests. The findings and how each was fixed are in
[Application_Security_Testing.md](Application_Security_Testing.md); the biggest was 17 vulnerabilities in npm's own packages, removed by leaving
npm out of the runtime image.

### Was there a penetration test or a dynamic scan?
No. There is no DAST (such as OWASP ZAP) or penetration test, and no authenticated testing because there is no authentication. They are listed as
next steps.

### How are secrets kept out of a public repository?
A pre-commit hook, a required CI check that scans every file and every added line, GitHub secret scanning with push protection, and git-ignored
files for every real value: [SECRET_SCANNING.md](SECRET_SCANNING.md). Real account IDs, addresses and domains never appear in committed files.

### Why are some Checkov findings skipped?
Each skip in `.checkov.yaml` has a reason (for example, demo-size choices such as a single NAT gateway, or a rotation function that never touches
the database and needs no VPC). A new finding fails the pull request check. Resources behind the optional switches are invisible to CI, so they
were scanned separately on 2026-11-08.

## CI/CD and releases

### What do the workflows do?
- `validate.yml` on pull requests: Terraform format and validate (both stacks and Region B), appspec check, unit tests and `npm audit`, the rotation tests, the image build and Trivy scan, Semgrep, Checkov and the secret scan. Six checks, all required.
- `deploy.yml` on a push to `main` that changes the app (or by hand): test, build, push a commit-SHA tag, wait for the ECR scan, register a task definition, run a CodeDeploy blue/green deployment.
- `codeql.yml` and `scheduled-scan.yml`: CodeQL, and a weekly rebuild-and-scan of the image, on Mondays.

Terraform is **not** applied by the pipeline: infrastructure is applied by hand. Details in [CICD.md](CICD.md).

### How does the pipeline get AWS access? Are there stored keys?
GitHub OIDC: the job exchanges a short-lived token for temporary credentials for the deploy role. No AWS keys are stored. The role trusts only
this repository (pinned by its immutable IDs) and the `dev` environment, which accepts only protected branches.

### How long does a deployment take?
About 16 minutes: CodeDeploy shifts traffic 10 percent a minute (about 10 minutes), then keeps the old tasks for 5 minutes for an instant
rollback. Only one deployment runs at a time.

### What if a release is broken?
Tested on 2026-11-02 with a container that crashes at start-up: **no request failed**, the broken tasks never received traffic, and a manual stop
with automatic rollback restored the original in about 35 seconds. CodeDeploy does **not** fail such a deployment by itself quickly (still
running after 30 minutes), so stop it yourself: `aws deploy stop-deployment --deployment-id <id> --auto-rollback-enabled`
([Rollback_Test.md](Rollback_Test.md)).

### Why can I not push to `main`?
Branch protection requires a pull request with six passing checks and an up-to-date branch, and it applies to administrators. A direct push is
refused. Work on a branch, open a pull request and merge when the checks pass.

### Why did Dependabot open a pull request?
Every action is pinned to a full commit SHA, so none update by themselves; Dependabot opens one grouped pull request a week (Mondays) for the
actions, and separate ones for npm packages and the base image. The checks run on each. Read what changed, then merge.

### Why did a workflow fail with an unpinned action?
The repository refuses actions that are not pinned to a full commit SHA. Write the line as `owner/action@<sha> # <tag>`.

### Why did the deploy fail at the AWS login?
Most often `AWS_DEPLOY_ROLE_ARN` was empty (a hidden paste into `gh secret set` can arrive empty). Set the secret from the Terraform output
with `printf '%s' "$ARN" | gh secret set AWS_DEPLOY_ROLE_ARN`. More in [CICD.md](CICD.md).

## Scaling

### How does it scale?
Application Auto Scaling keeps **2 to 4 tasks** with two target-tracking policies: average CPU at 60 percent and about 500 requests per task per
minute. Scale-out reacts within minutes; scale-in is slower on purpose (CloudWatch needs about 15 minutes of low load first). The commands are in
[runbook.md](runbook.md#6-scale).

### Why did my scaling test not scale?
The load must last **at least 5 minutes**: the scale-out alarm needs three consecutive minutes above the target. A shorter burst never
triggers it. In the test, scale-out came about 5.5 minutes after the load began and the first scale-in about 18 minutes after it ended.

### Why do 4 tasks matter for the database?
Each task opens up to 10 connections, so 4 tasks can open 40. Check that against the database's connection limit before raising the maximum.

### What is Fargate Spot doing here?
With `enable_fargate_spot`, two tasks always run on on-demand Fargate (in different zones) and tasks above two use Spot at a lower price.
Stopping a Spot task cost no failed requests in the test ([Fargate_Spot.md](Fargate_Spot.md)).

## HTTPS and DNS

### How is HTTPS set up?
`enable_https` creates an ACM certificate (validated in your existing Route 53 zone, which Terraform only reads), a 443 listener with TLS 1.3, an
HTTP-to-HTTPS redirect and a Route 53 alias record. The ALB to task hop is plain HTTP inside the VPC
([HTTPS_and_Domain.md](HTTPS_and_Domain.md)).

### Why does the destroy remove my DNS record but not the others in the zone?
Terraform only reads the hosted zone and manages just its own records and the certificate-validation records, so the rest of the zone is
untouched. After the last teardown the zone held only records for other sites.

## Disaster recovery

### What does the DR option build?
A pilot-light second Region (`us-west-2`): its own VPC, ALB with its own certificate, one ECS task and an Aurora secondary cluster, with
Aurora Global Database replication, the database secret and the ECR images replicated, and a Route 53 failover record. The design is in
[DR_Design_Decisions.md](DR_Design_Decisions.md).

### What did the drills measure?
On 2026-11-07: database failover with data loss allowed, the new writer ready in 31 to 38 s with 0 of 20,764 acknowledged rows lost (replication
lag at most 0.7 s at about 520 writes a second); the main name moving to Region B in 42 to 56 s when Region A's tasks were gone (about 3 minutes
when they ran but failed their health checks); a planned switchover in 56 s and back in 53 s; fail-back refused for 13 minutes while AWS resynced
the old primary. Everything, with every issue and the fix, is in [DR_Test_Results.md](DR_Test_Results.md).

### What is not proven?
A real Region outage (nothing can simulate one), heavier or bursty write loads, the scheduled rotation, and the cause of Region B's brief
500/503 when its cluster is demoted. Database promotion and scaling Region B up are manual. See the unproven list in the results.

### How do I run the drills again?
Follow [DR_Runbook.md](DR_Runbook.md), which also has the whole deploy, test, drill and destroy order (section 7). Plan on about 6 to 8 hours and a
few dollars.

### Why does the alarm lag, and does Route 53 follow it?
Route 53 reads the **metric data** the alarm watches, not the alarm's state. In the drill the health check turned unhealthy after about 5
minutes and the alarm's own state changed after 8 min 41 s, so do not rely on the alarm state to see a failover coming.

## Cost

### What does it cost?
About $0.14 an hour (about $3.30 a day) while the default stack runs, mostly the NAT gateway, the ALB, the database and the tasks; they bill even
with no traffic. With the whole DR design on, the estimate was about $0.35 to $0.50 an hour for the paid session. Destroy the stack when you are
done, and set an AWS Budgets alert as a safety net. These are estimates; Cost Explorer lags by many hours.

### What bills while nothing is using it?
The NAT gateway, the ALB, the database (an Aurora cluster has a minimum capacity), the tasks, and Container Insights and log storage in small
amounts. Region B adds its own NAT gateway, ALB and Aurora instance.

## Terraform and state

### Where is the state?
In S3 with native locking, one key for the main stack and one for Region B, in a bucket shared with other projects. The bucket name comes from the
git-ignored `backend.hcl`, so every `init` needs `-backend-config=backend.hcl`. The bootstrap stack's state is a local file.

### Where do my real values go?
In git-ignored files only: `terraform/demo.auto.tfvars`, `terraform/region-b/terraform.tfvars` and `backend.hcl`. Everything committed uses
placeholders. The reasons and the scanner are in [SECRET_SCANNING.md](SECRET_SCANNING.md).

### In what order do I apply a fresh stack?
ECR first (the tasks cannot start without an image): apply only the ECR repository, push the image, then apply the rest. With DR, create the
Region B repository before the first push and apply the main stack's replication rule first. The exact order is in
[DR_Runbook.md](DR_Runbook.md) and [runbook.md](runbook.md).

### Why did the destroy stop with `ResourceInUse` on a target group?
CodeDeploy points the listener at the green target group, which Terraform cannot see. The listeners now depend on it, so this is fixed; if it
happens, run the destroy plan and apply again and it continues where it stopped.

### Can I run `terraform apply` in the middle of a failover drill?
No. A failover changes which cluster is the writer, so Terraform's picture is wrong until you fail back. Fail back first.

## Operating and troubleshooting

### How do I check that a deployment is healthy?
`./scripts/verify-deployment.sh` (read-only; `--skip-plan` skips the drift check). It checks the stack, HTTPS, the database, the secret and its
rotation and the replica when they are on. With DR on, check Region B directly (`/health` and `/products` on its name) because the script does
not cover it.

### Where are the logs?
Container logs in CloudWatch (`/ecs/product-service`), ALB access logs in the central private S3 bucket, and optional CloudTrail, S3 access logs
and RDS logs behind switches: [Logging_Runbook.md](Logging_Runbook.md).

### I see 502 or 503 from the load balancer. What now?
503 usually means no healthy targets (tasks still starting, failing health checks, or none running); look at the ECS service events and the target
group health. A rare 502 during load was traced probably to Node's keep-alive timeout being shorter than the ALB's, fixed in `server.js`. A brief
503 or 500 can also appear while a database failover or a Region B demotion is in progress. The troubleshooting guide by symptom is in
[DR_Test_Results.md](DR_Test_Results.md#4-troubleshooting-guide) and [Deployment.md](Deployment.md#6-debug).

### How do I remove everything?
Destroy Region B first (`terraform -chdir=terraform/region-b destroy`), then the main stack, and run the leftover checks in both Regions; fail
back first if Region B is the database writer. With only the default stack, `terraform -chdir=terraform destroy`. Steps and checks:
[DR_Runbook.md](DR_Runbook.md#5-teardown-do-not-skip-and-do-not-leave-it-overnight).
