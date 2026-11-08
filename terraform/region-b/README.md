# Region B: the recovery Region (pilot light)

A separate Terraform stack with its own state, for the disaster recovery design in
[docs/DR_Design_Decisions.md](../../docs/DR_Design_Decisions.md). **Applied and drilled once on 2026-11-07 ([results](../../docs/DR_Test_Results.md)), then destroyed.**

| Piece | What | Status |
|---|---|---|
| 3a | The network: VPC, two zones of public and private subnets, one NAT gateway, the S3 gateway endpoint, and the ALB, app and database security groups | **This folder** |
| 3b | The database: a KMS key, the Aurora secondary cluster and its serverless instance (`database.tf`; reads the main stack's outputs in `main-state.tf`) | **Added** |
| 3c | The app: Region B's ECR repository, the load balancer with its own certificate and name (`dns.tf`, `alb.tf`), the ECS cluster and one task (`ecs.tf`); the main stack gets the ECR replication rule | **Added** (applied and drilled on 2026-11-07) |

## Use

```bash
cd terraform/region-b
cp backend.hcl.example backend.hcl        # set the state bucket name (git-ignored)
# terraform.tfvars (git-ignored): state_bucket = "<the same bucket>" and alb_ingress_cidr = "<your-ip>/32"
terraform init -backend-config=backend.hcl
terraform plan -out=region-b.tfplan
terraform apply region-b.tfplan
```

The main stack is applied first with `enable_aurora = true` and `enable_dr_replica = true` (it creates the global cluster this stack attaches to, and replicates the secret here). Its outputs are read from its state, so this stack cannot be planned until then. **Destroy this stack first**, then the main one.

## Order of use (the paid session)

1. ECR first, in this order: the main stack with `enable_aurora = true`, `enable_dr_replica = true` and a **targeted apply** of the ECR repository and the replication rule (`aws_ecr_replication_configuration.dr`), because **images are copied only if they are pushed after the rule exists**; then a **targeted apply of this stack's own ECR repository** (`-target=aws_ecr_repository.app -target=aws_ecr_lifecycle_policy.app`), because if the first push reaches Region B first, replication creates the repository itself and this stack's create then fails with "already exists"; then push the first image; then the main stack's full apply and the schema load.
2. This stack: `terraform apply`. The one task starts from the replicated `:latest`, reads the replicated secret and the Aurora secondary's reader endpoint, and answers on `app_domain`.
3. Check Region B directly through `app_domain` before any failover.
4. Failover DNS: set `failover_domain` (the main name) and `enable_failover_record = true`. The main stack must already have its PRIMARY record (`enable_dr_failover = true` there). Region B's certificate covers `failover_domain` as well, because after a failover Route 53 answers that name with this load balancer.

Before step 1 check the account's existing ECR replication configuration (`aws ecr describe-registry`): the rule in the main stack **replaces** it, because replication is configured once per registry.

## Design notes

- **Same posture as Region A:** private tasks behind a NAT gateway, no public IPs, security groups chained internet to ALB to app to database. The ALB admits only `alb_ingress_cidr`, and `0.0.0.0/0` is refused unless `allow_public_alb` is set.
- **Range:** `10.1.0.0/16`, so it never overlaps Region A's `10.0.0.0/16`.
- **Names:** resources use `product-service-b-...`, so they cannot be confused with Region A's.
- **One task, rolling deploys:** the service has no CodeDeploy; it scales by hand in a failover (`aws ecs update-service --desired-count`), and a deployment circuit breaker rolls back a bad task.
- **Database:** the task connects to the secondary's **reader endpoint**. The product service only reads, so it works before a failover and after the promotion.
- **Secret:** the task role may read only the replica of the database secret, found by name.
- **Failover DNS:** this stack holds the SECONDARY half of the failover pair; the PRIMARY (Region A's record and its alarm-driven health check) is in the main stack (`failover.tf`). The two stacks create separate records with the same name and different set identifiers.
- **The certificate covers both names** (`app_domain` and `failover_domain`). Both Regions use the same DNS validation record for the shared name, so destroying one stack removes a record the other's certificate renewal needs; fine for a short session, worth knowing.
- **No ALB access logs** in Region B (a second regional log bucket is not worth it for a short-lived pilot light); the exception is explained in `alb.tf`.
