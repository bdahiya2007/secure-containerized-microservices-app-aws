# Security review after the disaster recovery build

**Status:** a read-through of the Terraform, the Lambda and the open-item lists, done on 2026-11-08 after the DR drills. It is **not** a fresh scan: the Trivy, Checkov and `npm audit` re-runs are listed at the end as not yet done. GitHub's own scanners show no open alerts today (code scanning, Dependabot and secret scanning: 0 each), and every pull request's six required checks pass.

## What the DR build added, and how each part is secured

| Part | Security controls found in the code | Open point |
|---|---|---|
| Region B load balancer | Security group admits only `alb_ingress_cidr` on 443 and 80, and refuses `0.0.0.0/0` unless `allow_public_alb` is set (same guard as Region A); egress only to the VPC on 3000; HTTPS with its own ACM certificate | Same as Region A: no authentication on the API, so the address restriction is the guard |
| Region B tasks | Private subnets, task role limited to the replica secret, `DB_SSL=true` | The app does not verify the database certificate (same gap as Region A) |
| Aurora (both Regions) | `storage_encrypted`, storage encrypted (Region B with its own customer-managed KMS key; Region A with the AWS-managed `aws/rds` key when this review was written, since changed to a customer-managed key in the `fix/aurora-secret-kms-keys` branch, not yet applied), `publicly_accessible = false`, a database security group that admits only the app group on 5432 | `deletion_protection = false`, `skip_final_snapshot = true`, IAM database authentication off: demo choices that Checkov accepts with reasons |
| Database secret | Self-managed, write-only value (never in state), replicated to Region B, rotated every 7 days | The Region A secret now has a customer-managed key (code written, not yet applied); the Region B replica still uses the AWS-managed key there, because the Region B key is created after the main stack |
| Rotation Lambda | Role trusts only Lambda in this account; the policy names one secret and one cluster; `GetRandomPassword` and X-Ray actions need `*` because they take no resource; the invoke permission allows only Secrets Manager from this account; no database login (it calls `ModifyDBCluster`) | Not in a VPC and no code signing, dead-letter queue or reserved concurrency: acceptable for a function only Secrets Manager can call, but not confirmed against a fresh Checkov run |
| ECR replication | One registry-wide rule to Region B | The rule replaces any other registry replication setting in the account (checked first in the runbook) |
| Route 53 failover | Health check follows an alarm's metric data | Failover is automatic only for DNS. Database promotion and scaling Region B up are manual steps, so a real Region outage still needs a person |
| Deploy role | PassRole now also covers Lambda, still limited to `product-service-*` roles | No permissions boundary (already listed) |

## Leftovers a failover creates

- AWS takes a snapshot named `rds:unplanned-global-failover-...` of the old primary. It holds a copy of the database, is not in Terraform, and survives `terraform destroy`. It is on the teardown checklist ([DR_Runbook.md](DR_Runbook.md), section 5); delete it, or the data stays billable and readable by anyone with RDS access.
- KMS keys are scheduled for deletion, not removed at once (7-day window).

## Open items that matter most

1. **No authentication on the API** (medium, unchanged). Both load balancers rely on `alb_ingress_cidr`.
2. **Region A's app uses the writer endpoint** (found in the drills): reads fail for about 32 seconds in a switchover. A reliability gap more than a security one.
3. **Database TLS does not verify the certificate**, in both Regions.
4. **A real Region outage cannot be simulated**, so the claim "Region B takes over" is proven for task loss and database failover, not for a whole Region going dark.
5. **The scheduled 7-day rotation has not run yet**; only manual rotations were tested.

## Stale statements fixed in the README and Architecture.md in the same change

The lists had not been revised since the DR build and still said, for example, that CI has no scanning (it has Trivy, Checkov, Semgrep, CodeQL and a secret scan), that there is no static analysis, that there are no automated tests (30 unit tests plus 16 for the rotation function), that `main` is unprotected, and that the database is single-AZ RDS (Aurora Serverless v2 is used when `enable_aurora` is on).

## Re-scan on 2026-11-08

Trivy, Checkov and `npm audit` were re-run locally; the results are in [vulnerability-scan-report.md](vulnerability-scan-report.md#re-scan-on-2026-11-08-after-the-dr-build). The main point: with the DR switches **on**, Checkov reports 6 failed checks on 3 resources that CI never sees, because CI scans the code with every switch at its default (off).

## Not done yet

- A scan of the Lambda's dependencies: it uses only the standard library and the Lambda runtime's boto3.
