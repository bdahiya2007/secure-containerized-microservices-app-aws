# Application security testing

What was tested, with which tool, what it found, and how each finding was handled. Everything here is taken from the scan reports, the CI
configuration and the test records in this repository; where something was **not** done, it says so. The detailed image and Terraform findings
are in [vulnerability-scan-report.md](vulnerability-scan-report.md), the design-level view is in [THREAT_MODEL.md](THREAT_MODEL.md), and the
policy for keeping secrets out is in [SECRET_SCANNING.md](SECRET_SCANNING.md).

**Scope:** the Product Service (`product-service/`, Node.js and Express), its container image, the rotation function (`lambdas/db-rotation/`,
Python), the Terraform in `terraform/` (including `region-b/` and `bootstrap/`) and the GitHub Actions pipeline. **Last full re-scan:**
2026-11-08.

## What is covered, and what is not

| Technique | Tool | Runs | Covers | Latest result |
|---|---|---|---|---|
| **SAST** (static code analysis) | **Semgrep** 1.183.0, rule sets `p/nodejs`, `p/javascript`, `p/owasp-top-ten`, `p/secrets` | Every pull request (required check "Code security scan (Semgrep)"; `--error`, so any finding fails it) | `product-service/src` | Pass |
| | Semgrep with `p/python`, `p/owasp-top-ten`, `p/secrets` | Every pull request | `lambdas/db-rotation/` | Pass |
| | **CodeQL** (`javascript-typescript`) | Pull requests, pushes to `main` and weekly (Mondays) | The Node.js application | 0 open alerts |
| **SCA** (dependencies) | **`npm audit --omit=dev`** | Every pull request and weekly | Production dependencies in `package-lock.json` | 0 vulnerabilities (2026-11-08) |
| | **Trivy `fs`** | Every pull request | `package-lock.json` and secrets in `product-service/` | 0 vulnerabilities, 0 secrets |
| | **Dependabot** | Weekly (Mondays) | npm packages, the base image and the pinned GitHub Actions | Grouped update pull requests, 0 open security alerts |
| **Container image** | **Trivy `image`** (0.76.1, vulnerabilities and secrets) | Every pull request (fails on HIGH or CRITICAL with a fix) and weekly from `main` | The built image: Alpine OS packages and Node packages | 1 MEDIUM (`zlib`), no HIGH or CRITICAL |
| | **Trivy `config`** | Every pull request and by hand | The Dockerfile | 0 misconfigurations |
| | **ECR scan on push** | Every deploy (the workflow waits and stops on CRITICAL) | The pushed image | `COMPLETE`, no findings (2026-10-29) |
| | A non-root check | Every pull request | That the image runs as the `node` user | Pass |
| **IaC** | **Checkov** 3.3.29 with reviewed exceptions in `.checkov.yaml` | Every pull request (required check "Terraform security scan") | `terraform/`, including `region-b/` | 279 passed, 0 failed (switches at their defaults); 311 passed, 0 failed with the DR switches on |
| | **Trivy `config`** | By hand | `terraform/` | 15 distinct checks fail: known, accepted demo choices |
| **Secrets** | The project's own scanner, plus GitHub secret scanning with push protection | Pre-commit hook, every pull request, every push | Every tracked file and every added line | Pass; 0 open alerts |
| **Unit and logic tests** | Node's test runner (30 tests), Python `unittest` (16 tests) | Every pull request | Routes, secret reading, database settings, and the rotation function's steps | Pass |
| **Behavioural and resilience tests** (dynamic, by hand) | `curl`, load generators, `scripts/dr-probe.sh`, CodeDeploy and Route 53 drills | Once, on a live stack | Load, a broken release and its rollback, password rotation, database and DNS failover | Results in [Load_Test_and_Optimization.md](Load_Test_and_Optimization.md), [Rollback_Test.md](Rollback_Test.md), [Secrets.md](Secrets.md) and [DR_Test_Results.md](DR_Test_Results.md) |

**Not done, so no claim is made about it:**
- **DAST** (a dynamic scanner such as OWASP ZAP or Burp run against the live service). The service has three read-only routes and no user input
  reaches a query, but it has not been scanned dynamically.
- **A penetration test**, fuzzing of the HTTP routes, or authenticated testing (the API has no authentication).
- **Interactive or manual code review by a second person** (a single-owner project).
- **Scanning of the Lambda's runtime dependencies** (it uses only the standard library and the runtime's `boto3`).
- **A scan of the live ALB's TLS configuration** with an external tool. TLS 1.3 was checked with `curl`, not graded by a scanner.

## Frameworks and standards behind the scans

No formal compliance framework (CIS, NIST, ISO 27001, SOC 2, OWASP ASVS) was adopted or audited against. The scans use the tools' own rule sets
and public vulnerability data, and the design is reasoned with STRIDE. What each layer is based on:

| Layer | What it is based on |
|---|---|
| **Source code** | Semgrep's registry rule sets for Node.js and JavaScript, and its **OWASP Top 10** set (`p/owasp-top-ten`); CodeQL's default JavaScript query suite. These are rule libraries, not a certification: passing them means "no known pattern matched", not "secure" |
| **Dependencies** | The npm advisory database (`npm audit`), the GitHub Advisory Database (Dependabot) and the public vulnerability databases Trivy reads (distribution advisories for Alpine and the language advisories for npm packages) |
| **Container images** | Trivy (OS and application package CVEs, embedded secrets, Dockerfile misconfigurations) and ECR's **basic** scan-on-push. The image is also built to common hardening practice: minimal Alpine base with only the `node` binary (no npm), a non-root user and a read-only root filesystem |
| **Infrastructure as code** | Checkov's policy library and Trivy's misconfiguration checks for Terraform. Many of Checkov's AWS checks correspond to the CIS AWS Foundations Benchmark and AWS security best practices, but the project does not claim CIS compliance; each skipped check has its reason in `.checkov.yaml` |
| **AWS account and runtime** | **No AWS-native security scanner is enabled by this project's Terraform**: not Security Hub, Inspector (so ECR uses the basic scan, not Inspector's enhanced scanning), GuardDuty, AWS Config, IAM Access Analyzer, Macie or a WAF. The AWS-side protections that exist are preventive controls (private subnets, chained security groups, scoped IAM roles, confused-deputy conditions, encryption, TLS) plus optional CloudTrail, S3 access logs and RDS logs, all described in [Architecture.md](Architecture.md) |
| **Design and threats** | **STRIDE** in [THREAT_MODEL.md](THREAT_MODEL.md), and the AWS Well-Architected security practices used informally as a checklist (least privilege, defence in depth, protect data in transit and at rest) |

Adding AWS Security Hub with the AWS Foundational Security Best Practices standard, GuardDuty and Inspector's enhanced ECR scanning is the
natural next step for the account-level view; each bills by usage, so it is listed as a roadmap item, not built.

## Findings and remediation

Newest first. "Status" is as of 2026-11-08.

| # | Date | Tool or test | Finding | Severity | Remediation | Status |
|---|---|---|---|---|---|---|
| 1 | 2026-11-08 | Checkov (DR switches on) | The Region A Aurora cluster and the database secret used AWS-managed keys (CKV_AWS_327, CKV_AWS_149) | Low | A customer-managed KMS key for both, with narrow `kms:Decrypt` and `kms:GenerateDataKey` grants through Secrets Manager only (PR #53) | **Fixed in code, not yet applied** (stack destroyed) |
| 2 | 2026-11-08 | Checkov (DR switches on) | Rotation function without a VPC, dead-letter queue, concurrency limit or code signing (CKV_AWS_117, 116, 115, 272) | Low | Accepted in `.checkov.yaml` with reasons: it only calls AWS APIs, is invoked synchronously by Secrets Manager only, and is deployed only through Terraform | Accepted |
| 3 | 2026-11-08 | Trivy `image` | `zlib` 1.3.2-r1, CVE-2026-4738 (bounds check), fix in 1.4-r0 | Medium | None yet: CI blocks only HIGH and CRITICAL with a fix. A rebuild on a base image that carries the fix clears it | **Open** |
| 4 | 2026-11 | Semgrep (Python) | Log lines in the rotation function that put "secret", "password" or "token" next to a variable were flagged by the logging-credential rule. No value was logged | Low (false positive) | The messages were reworded so they no longer match; no value is logged | Fixed |
| 5 | 2026-11-07 | Live rotation on Aurora (the first one) | A retry livelock: the rotation kept resetting the password and never finished | Medium | The function labels the version once it has set it, skips the step on a retry, and clears the leftover labels when it finishes; 16 offline tests (PRs #45 and earlier) | Fixed and re-tested live (104 s, no failed request) |
| 6 | 2026-11-02 | Live rotation test under load | A retry race during a forced rotation | Medium | Fixed in the app: it fetches the secret again after a rotation; re-test: 100 of 100 parallel requests succeeded | Fixed |
| 7 | 2026-11-02 | Load test | One ALB-generated 502 in about 40,000 requests: Node's 5 s keep-alive was shorter than the ALB's 60 s idle timeout | Low | `keepAliveTimeout` 65 s and `headersTimeout` 66 s in `server.js`; a repeat load test had zero 5XX, which is consistent with the fix but does not prove it | Fixed; cause is probable, not proven |
| 8 | 2026-11-01 | Operations review (an incident) | The load balancer's security group was briefly opened to `0.0.0.0/0` because a settings file was missing and the variable had a default | Medium | `alb_ingress_cidr` has no default, `0.0.0.0/0` is refused unless `allow_public_alb = true`, and the plans were tested ([E2E_Test_Results.md](E2E_Test_Results.md)). The service exposed only `/health` and `/products` with sample data during the window | Fixed |
| 9 | 2026-10-31 | Checkov (initial run, then re-scans) | 28 failed checks (80 passed) in the first run | Mixed | Fixed in code where possible (HTTPS and logging among them); the rest accepted with a reason per check in `.checkov.yaml`. Result: 166 passed, 1 failed, then 279 passed, 0 failed in CI | Fixed or accepted |
| 10 | 2026-10-29 | Trivy `config` (Terraform) | 19 failed checks (2 CRITICAL, 3 HIGH, 3 MEDIUM, 11 LOW) | Mixed | Fixed where possible; 15 distinct checks remain as documented demo choices (HTTP listener without a domain, open 443 egress, mutable ECR tags, AWS-managed keys) | Accepted, listed in the README gaps |
| 11 | 2026-10-28 | Trivy `image` | **17 vulnerabilities (6 HIGH, 10 MEDIUM, 1 LOW)**, all in npm's own bundled packages (`undici`, `brace-expansion`, `ip-address`, `postcss-selector-parser`) | High | npm is not needed at runtime, so the Dockerfile is multi-stage: a minimal Alpine runtime stage with only the `node` binary and the production dependencies. Re-scan: **0**; the image shrank from 258 MB to 220 MB | **Fixed** (re-scanned 2026-10-29) |
| 12 | 2026-10-28 | Trivy `image` on a proposed migration image | The official `postgres:18-alpine` image had **85 vulnerabilities (2 CRITICAL)** | High | Rejected; the migration task runs the app's own image, which has 0 | **Fixed** (design change) |
| 13 | 2026-10-24 | `npm audit --omit=dev` | None (0 vulnerabilities), and again 0 on 2026-11-08 | n/a | n/a | Clean |
| 14 | Ongoing | Design review | The service has **no authentication**; the load balancer admits one address | Medium | Address restriction by default (finding 8's guard); authentication and a WAF are listed as the planned fix | **Open** (accepted for a demo) |
| 15 | Ongoing | Design review | The app encrypts its database connection but does **not verify the server certificate** (`rejectUnauthorized` defaults to false) | Low | Planned: bundle the AWS RDS CA and set `DB_SSL_REJECT_UNAUTHORIZED=true` | **Open** |
| 16 | Ongoing | Trivy and the README gaps | ECR image tags are mutable (`latest`); the base image is pinned by tag, not digest | Low | The pipeline pushes unique commit-SHA tags; making the repository immutable needs the task definition to stop starting from `latest` | **Open** |
| 17 | Ongoing | Trivy | The Brotli CVE-2026-111497 in the Node binary: patched in Node 26.12.1 and later according to public sources; not tested with crafted input | Low | Keep the base image current | **Open** (not verifiable by the scanner) |

## How findings are handled

1. **CI decides.** Semgrep (`--error`), Checkov, Trivy (HIGH and CRITICAL with a fix) and the secret scan fail the pull request check, and all
   six checks are required for `main`, for administrators too. A finding therefore has to be fixed or explicitly accepted before merging.
2. **Accepting a finding means writing the reason.** Every skipped Checkov rule is in `.checkov.yaml` with a comment saying why, and each
   accepted risk appears in the README's "Open security gaps" table, so nothing is silently ignored.
3. **Fix the cause, then re-scan.** The image findings were fixed by changing the build (removing npm from the runtime), not by suppressing them,
   and the re-scan result is recorded next to the original finding.
4. **Scans repeat without a change.** The weekly scheduled scan and CodeQL run on Mondays even when nobody pushes, so a newly published
   vulnerability in an unchanged image is found within a week (the last scheduled run succeeded).
5. **Latent findings are looked for.** CI scans with every optional switch at its default, so resources behind the DR switches are invisible to
   it. They were scanned separately on 2026-11-08 (findings 1 and 2), and this should be repeated whenever those files change.

## Run it yourself

```bash
# Dependencies
(cd product-service && npm audit --omit=dev)

# Image: build it, then scan it (Trivy runs from its container image; pin the version CI uses)
docker build -t product-service:scan product-service
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock aquasec/trivy:0.76.1 image --scanners vuln,secret product-service:scan
docker run --rm -v "$PWD/product-service:/work:ro" aquasec/trivy:0.76.1 config /work

# Terraform (CI runs this; to include the DR resources, scan a copy with the DR switches in a tfvars file)
checkov --config-file .checkov.yaml

# Code (the CI invocation is in .github/workflows/validate.yml)
semgrep scan --config p/nodejs --config p/javascript --config p/owasp-top-ten --config p/secrets product-service/src

# Secrets
python3 scripts/secret-scan.py --all-tracked
```

## What would raise the assurance next

- A dynamic scan (OWASP ZAP baseline) against a running stack, and a TLS grade of the HTTPS listener.
- Verify the database certificate (finding 15), then add a test that the app refuses a connection with a wrong certificate.
- Immutable image tags and a digest-pinned base image (finding 16).
- Authentication in front of the API, then authenticated tests.
- Automate the DR-switches Checkov run in CI so latent findings stop being invisible.
