# HTTPS and a custom domain (Route 53 + ACM)

The load balancer serves plain HTTP on its own address by default. With `enable_https = true` the app is served at a name in a Route 53 hosted zone you already own, over HTTPS, and port 80 redirects to it. **Applied and verified on the live stack on 2026-11-01** (results at the end).

## What it adds

| Piece | Detail |
|---|---|
| Certificate | A free ACM certificate for `app_domain`, validated by a DNS record in your zone |
| Listener | HTTPS on 443 with the `ELBSecurityPolicy-TLS13-1-2-2021-06` policy. With blue/green, **CodeDeploy shifts traffic on this listener** |
| Redirect | A rule on the port-80 listener sends every request to HTTPS (301) |
| DNS | An `A` alias record for `app_domain` pointing at the load balancer |
| Security group | Port 443 from `alb_ingress_cidr`, next to port 80 (the redirect) |
| Output | `app_url` is `https://app_domain` (otherwise the load balancer's HTTP address); `verify-deployment.sh` uses it |

The hosted zone is only **read**. The stack creates the validation records and one alias record, so `terraform destroy` removes only those and never other records in the zone. Cost: ACM and alias records are free; the zone already exists.

## Turn it on

Put the real names in the untracked `terraform/demo.auto.tfvars` (domain names stay out of the repository):

```hcl
enable_https     = true
app_domain       = "products.example.com"   # your name
hosted_zone_name = "example.com"            # an existing public zone
```

1. **Before the apply**, note which target group is live (with blue/green, CodeDeploy leaves the listener on blue or green):
   ```bash
   aws elbv2 describe-listeners --load-balancer-arn "$(aws elbv2 describe-load-balancers --names product-service-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text)" \
     --query 'Listeners[0].DefaultActions[0].ForwardConfig.TargetGroups[?Weight>`0`].TargetGroupArn'
   ```
2. `terraform plan` and `terraform apply` (the certificate validates in a few minutes). Expect adds only, plus an **in-place** update of the CodeDeploy deployment group (its listener). Nothing is replaced and there is no outage.
3. **If step 1 showed the green target group** (`product-service-tg-green`): the new 443 listener starts on blue, so point it at the live group once, or the app answers 503 on HTTPS until the next deployment:
   ```bash
   aws elbv2 modify-listener --listener-arn <the 443 listener ARN> \
     --default-actions Type=forward,TargetGroupArn=<the live target group ARN>
   ```
4. Check: `curl -I http://products.example.com/health` (301 to HTTPS) and `curl https://products.example.com/health`, then `./scripts/verify-deployment.sh`.

Turn it off by setting `enable_https = false` and applying: the deployment group goes back to the port-80 listener, and the certificate and records are removed. (If the HTTP listener's default action points at the idle target group at that time, move it to the live one the same way.)

## Public only during demos

The load balancer admits only `alb_ingress_cidr` (your address as a `/32`), because the API has no authentication. To let anyone open the URL for a demo, set both of these in `demo.auto.tfvars` and apply, then **put them back and apply again** when the demo ends:

```hcl
alb_ingress_cidr = "0.0.0.0/0"
allow_public_alb = true
```

While it is open: anyone can call `GET /products`, load can scale tasks up and raise cost, and there is no WAF. The verify script's "ALB admits one /32" checks will fail on purpose while it is open. Closing it again restores them.

## Limits and notes

- **Region:** the certificate is created in the stack's Region (us-east-1), which is where an ALB needs it. A second Region needs its own certificate (relevant for [disaster recovery](Disaster_Recovery_Exploration.md)).
- **The ALB's own DNS name no longer matches the certificate.** Use `app_domain`; `curl -k` only for debugging.
- **Route 53 health checks** cannot reach an ALB that admits only one address; use a CloudWatch-alarm health check if that is needed later.
- **HTTP-only scanner exceptions** in `.checkov.yaml` stay, because the default (switch off) code still has an HTTP-only listener.

## Result of the first apply (2026-11-01)

The plan was 6 to add, 2 to change, 0 to destroy (the certificate and its validation record, the 443 listener and the redirect rule, the alias record, a 443 rule on the ALB security group, and the CodeDeploy deployment group switching to the 443 listener). The first plan wrongly replaced the ALB security group because a description had been reworded (AWS cannot change it in place); that was fixed before the apply.

| Check | Result |
|---|---|
| DNS | The name resolves to the load balancer (alias record) |
| Certificate | Valid Amazon certificate for the name, valid until 2027-05-18; verified by curl |
| `http://` | 301 to `https://` (a redirect followed ends at a 200) |
| `GET /health`, `GET /products` over HTTPS | 200 with `{"status":"ok"}` and the product data |
| `GET /nope` over HTTPS | 404 |
| TLS | TLS 1.3; TLS 1.1 refused |
| ALB's own address over HTTPS | Fails certificate verification, as designed |
| `verify-deployment.sh --skip-plan` | 34 passed, 0 failed, 1 skipped (the drift check); its endpoint checks run over HTTPS |

**What happened with the live target group:** CodeDeploy had left traffic on the green target group, so the new 443 listener (which starts on blue) answered 503. One `aws elbv2 modify-listener` pointed it at green, and about a minute later (the change takes a little while to apply) HTTPS answered 200. This is the step 3 above; check the live group first, as written.
