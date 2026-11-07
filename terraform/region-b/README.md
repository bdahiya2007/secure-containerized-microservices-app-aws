# Region B: the recovery Region (pilot light)

A separate Terraform stack with its own state, for the disaster recovery design in
[docs/DR_Design_Decisions.md](../../docs/DR_Design_Decisions.md). **Written in pieces; nothing here is applied yet.**

| Piece | What | Status |
|---|---|---|
| 3a | The network: VPC, two zones of public and private subnets, one NAT gateway, the S3 gateway endpoint, and the ALB, app and database security groups | **This folder** |
| 3b | The load balancer with its own certificate and `usw2.` name, the ECS cluster and one task | Next |
| 3c | A KMS key, the Aurora secondary cluster and its serverless instance | After 3b |

## Use (once all pieces exist)

```bash
cd terraform/region-b
cp backend.hcl.example backend.hcl        # set the state bucket name (git-ignored)
terraform init -backend-config=backend.hcl
terraform plan -var="alb_ingress_cidr=<your-ip>/32" -out=region-b.tfplan
terraform apply region-b.tfplan
```

The main stack is applied first (it creates the global cluster this stack attaches to). **Destroy this stack first**, then the main one.

## Design notes

- **Same posture as Region A:** private tasks behind a NAT gateway, no public IPs, security groups chained internet to ALB to app to database. The ALB admits only `alb_ingress_cidr`, and `0.0.0.0/0` is refused unless `allow_public_alb` is set.
- **Range:** `10.1.0.0/16`, so it never overlaps Region A's `10.0.0.0/16`.
- **Names:** resources use `product-service-b-...`, so they cannot be confused with Region A's.
