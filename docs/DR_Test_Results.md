# Disaster recovery: what was built, what the drills showed, what went wrong, and how to troubleshoot

**Status: one paid session on 2026-11-07, partly written up.** Drills 1 to 4 are recorded below. **Drill 4b (the alarm path) and Drill 5 (the database failover) are pending and marked as such.** Everything here is measured from the live session unless it says "hypothesis". Costs are estimates; Cost Explorer lags by many hours.

How to read it: [the session in one table](#1-the-session-at-a-glance), [the results of each drill](#2-results-by-drill), [every problem, with cause and fix](#3-issues-found-and-how-they-were-resolved), [a troubleshooting guide by symptom](#4-troubleshooting-guide), and [what is still unproven](#5-what-is-still-unproven). The plan the session followed is [DR_Runbook.md](DR_Runbook.md), the design is [DR_Design_Decisions.md](DR_Design_Decisions.md).

## 1. The session at a glance

| | |
|---|---|
| **Date** | 2026-11-07 (times below are UTC) |
| **Shape** | Region A (us-east-1): the full stack on an **Aurora Global Database primary** (Serverless v2, 0.5 to 4 ACU). Region B (us-west-2): its own network, an **Aurora secondary**, an HTTPS load balancer and **one** ECS task. Route 53 failover for the main name. The database password is in a **self-managed, replicated secret** rotated by a Lambda function |
| **Build** | Main stack: 70 resources planned; the first apply stopped on two errors (section 3, issues 1 and 2) and a second apply (6 added, 1 destroyed) completed it. Region B stack: **43 resources, no errors** |
| **Verification** | `verify-deployment.sh`: **37 passed, 1 failed, 4 skipped**. The one failure was ALB access logs not yet delivered on a brand-new load balancer. All seven new HTTPS, Aurora, rotation and failover checks passed on their first real run |
| **Cost** | About 3 hours at roughly $0.40 to $0.55 an hour (estimate). The AWS budget alert had been raised to $15 first |

**Results in one line each**

| Drill | Result |
|---|---|
| 1. Replication lag under write load | **Passed.** 30,295 inserts in 60 s: lag at most **728 ms**, average **64 ms** (target: under 60,000 ms) |
| 2. Password rotation end to end | **Failed first, a real flaw found and fixed; re-run passed.** 104 s, 141 of 141 requests answered |
| 3. Planned switchover to Region B and back | **Completed (56 s and 53 s), with a finding:** about **32 s of failed reads** on the main name; the expectation of "no gap" was wrong |
| 4. DNS failover (Region A's app stopped) | **Passed.** Region B answered the main name within about **56 s**; 12 failed probe requests over about 24 s; HTTPS stayed valid. The alarm path was **not** exercised (see 4b) |
| 4b. The alarm path | **Pending** |
| 5. Database failover with data loss allowed | **Pending** |

## 2. Results by drill

### Drill 1: replication lag under write load
A one-off task inserted rows for 60 seconds through the application's own database module (about 500 writes a second), then deleted them. The lag came from the Region B cluster's `AuroraGlobalDBRPOLag` metric.

| Minute | Max | Average |
|---|---|---|
| 1 (writes begin) | 2,154,963 ms | 10,142 ms |
| 2 (steady state) | **728 ms** | **64 ms** |
| 3 | 0 ms | 0 ms |

- **Reading it:** in steady state the secondary was under a second behind at 0.5 to 4 ACU, so AWS's recommendation of 8 ACU for the primary was not needed for this write rate. Cleanup left the 3 original rows in both Regions.
- **The first-minute value (about 36 minutes) cannot be real lag.** It appeared the moment the writes began after a long idle, when the metric read 0. **Hypothesis, not confirmed:** the metric compares against a stale timestamp until the first write is applied. To be re-checked in Drill 5, which also starts after an idle period.
- **Not measured:** how many ACUs the primary actually scaled to under this load.

### Drill 2: password rotation end to end
- **First run: did not complete.** The secret stayed `AWSPENDING` for 7 minutes (cause and fix: section 3, issue 6). The app answered every request throughout.
- **Recovery:** the rotation was finished by hand and a fresh task logged in with the new password (steps in the troubleshooting guide).
- **Re-run with the fixed function: passed.**
  - **Duration: 104 seconds** (22:03:42 to 22:05:26).
  - The function asked RDS for the change **once** (one "Reset master credentials" event). `testSecret` failed once, as expected, while RDS was resetting; the retry skipped the request, `testSecret` passed, and `finishSecret` made the new version current.
  - The new version was `AWSCURRENT` and the old one `AWSPREVIOUS` in **both Regions** (the Region B replica followed).
  - **141 of 141 probe requests returned 200**; Region B answered 200.

### Drill 3: planned switchover to Region B and back
| | |
|---|---|
| Switchover to Region B | **56 s** |
| Switch back to Region A | **53 s** |
| End state | Writer is Region A, global database `available` |
| Probe on the main name (234 requests) | **19 failed (503)**, one run of about **32 s** (the first failures came as the writer flipped) |
| Region B's app | Returned 500 after the switch back (still 500 at 22:18:09) and was fine again by 22:24:51, about 7 minutes after the switch back. **The exact duration was not measured** (polling stopped too early) |

- **The expectation that failed:** "the app only reads, so a switchover shows no gap" was wrong.
- **Likely cause (hypothesis):** Region A's app connects to the cluster (writer) endpoint. When Region A becomes a secondary, that endpoint stops serving until the cluster is back as a reader, and the app's open connections break. Region B's app uses the **reader** endpoint.
- **Planned fix, not yet applied:** make the read-only app in Region A use the reader endpoint too (the migration task keeps the writer endpoint), then re-test a switchover.

### Drill 4: DNS failover with Region A's service stopped
Region A's tasks were taken to zero (autoscaling minimum set to 0 first, then the service), and restored afterwards.

- **Region B answered the main name about 56 seconds after the service was stopped**, with HTTPS valid (Region B's certificate also covers the main name).
- **User-visible failures: 12 of 418 probe requests (503), one run of about 24 s**, all from Region A's load balancer once its targets were gone.
- **Restore:** two tasks running about 47 s after the restore, Region A answering again about 75 to 82 s.
- **Surprise:** the **CloudWatch alarm stayed `OK` and the Route 53 health check stayed healthy** for the whole outage, yet the name failed over. The likely reason is the PRIMARY record's alias has `evaluate_target_health` on, so Route 53 noticed the load balancer had no healthy targets within about a minute. The alarm needs 3 full minutes of no running tasks and was restored before it could trip. That means **the alarm-driven path, meant for a whole-Region outage, was not exercised** by this drill.

### Drill 4b: the alarm path (pending)
Same drill with Region A kept down until the alarm reaches `ALARM` and the health check turns unhealthy. *Results to be added.*

### Drill 5: database failover with data loss allowed (pending)
*Results to be added: lag before, promotion time, Region B scale-up time, total recovery time, and the fail-back.*

## 3. Issues found and how they were resolved

### During the build, before the session
| # | Issue | Cause | Resolution |
|---|---|---|---|
| a | Semgrep flagged four log lines in the rotation function | Its logger rule flags messages containing "secret" or "password" next to a variable; the lines logged only a cluster name or a version ID | Messages reworded (not suppressed) |
| b | Checkov findings appeared only on the Region B cluster | Checkov skips resources behind a switch that is off, so the Aurora checks never ran on the Region A cluster | Documented exceptions with reasons for both clusters |
| c | Region B's certificate would have failed on the main name after a failover | It covered only Region B's own name | The certificate now also covers the main name (a subject alternative name) |
| d | First image push would have broken Region B's apply | ECR replication auto-creates a missing repository, so Terraform's later create would fail with "already exists" | Create Region B's repository first (targeted apply), then push |
| e | A plan wanted to replace the load balancer's security group | A security group description had been reworded, and AWS cannot change a description in place | Caught in an offline plan before any apply; the original wording was restored |

### During the session
| # | Issue | How it showed | Cause | Resolution | Status |
|---|---|---|---|---|---|
| 1 | Lambda not created | `AccessDeniedException: not authorized to perform iam:PassRole` | The scoped IAM policy allowed passing the project's roles only to ECS tasks and CodeDeploy, not to Lambda | `lambda.amazonaws.com` added to the policy; the owner updated their permission set and logged in again; apply continued | Fixed |
| 2 | Route 53 health check not created | `Route 53 does not support extended CloudWatch metric statistics` | The alarm used metric math over two target groups. Route 53 supports **no metric math, no extended statistics and no "M out of N" alarms** | One-metric alarm: ECS Container Insights `RunningTaskCount` below 1 for 3 of 3 minutes. Trade-off: it watches tasks, not the load balancer's view of them | Fixed |
| 3 | Docker could not save the ECR login | `error saving credentials: The stub received bad data` (Docker Desktop credential helper under WSL) | The credential helper | Pushed with a temporary Docker config folder holding the login, deleted afterwards | Worked around |
| 4 | One verify check failed | "ALB access logs were delivered today" | A brand-new load balancer has not delivered logs yet (they arrive in batches) | None needed; expected to pass later | Timing |
| 5 | Region B's ECR looked different from Region A's | A first check read only the first image record | The push creates an image index plus platform images; Region B lists them separately | None: both Regions held identical records | Not a problem |
| 6 | **Rotation never finished (Drill 2, first run)** | Secret `AWSPENDING` for 7 minutes; RDS events showed repeated "Reset master credentials"; the cluster cycled between `resetting-master-credentials` and `available` | `setSecret` asked RDS for the change; RDS spends about 90 s resetting credentials; `testSecret`, running right after, failed; **Secrets Manager retries the whole rotation from the start, so every retry asked RDS again and restarted the reset**. The unit tests used a fake that answered instantly | Finished by hand (steps below); the function now labels the pending version after RDS accepts the request and skips it on a retry; two tests replay the retry loop. Re-run passed | Fixed |
| 7 | A test script reported "still pending after 6 minutes" on a rotation that had finished | Secrets Manager leaves the `AWSPENDING` label on the version that just became current | The script's check was wrong; the label is only cosmetic | The function now removes the leftover label (in the repo; not deployed in the session) | Cosmetic |
| 8 | **About 32 s of failed reads during a planned switchover (Drill 3)** | 19 failed probe requests; the main name returned 503 and 500 | Region A's app uses the cluster (writer) endpoint (hypothesis) | Planned: use the reader endpoint in Region A's app | **Open** |
| 9 | Region B returned 500 after the switch back | `/products` returned 500 for a while | Not diagnosed (the logs were not read) | Recovered by itself | **Open** |
| 10 | The first-minute lag value of about 36 minutes | An implausible spike when writes began | Hypothesis: an artifact of the metric after an idle period | To be re-checked in Drill 5 | **Open** |

**Process notes, for honesty:** the plan expected a DNS failover in 4 to 6 minutes and got about 56 seconds (better, for a reason that was not predicted); and it expected no gap in the switchover and got 32 seconds (worse). Both predictions came from reading documentation, and both were corrected by running the thing.

## 4. Troubleshooting guide

Commands use placeholders in angle brackets. Run everything for Region B with `--region us-west-2`.

**An apply stops with `AccessDenied` on `iam:PassRole`.** The role is being handed to a service the scoped policy does not allow. Add the service (for example `lambda.amazonaws.com`) to the `iam:PassedToService` list in [`iam/product-service-iam-policy.json`](iam/product-service-iam-policy.json), update the permission set that uses it, run `aws sso login`, and apply again (it continues where it stopped).

**A Route 53 health check is refused (`extended CloudWatch metric statistics`).** The alarm uses metric math, a percentile statistic or "M out of N" evaluation. Use one metric, a standard statistic (Average, Minimum, Maximum, Sum, SampleCount), and the same number for `evaluation_periods` and `datapoints_to_alarm`.

**`docker push` to ECR fails to log in (`The stub received bad data`).** Use a temporary config: `export DOCKER_CONFIG=$(mktemp -d); echo '{}' > $DOCKER_CONFIG/config.json`, log in and push, then `rm -rf $DOCKER_CONFIG; unset DOCKER_CONFIG`.

**The Region B task does not start, or `/health` fails.** (1) Is the image in Region B? `aws ecr describe-images --region us-west-2 --repository-name product-service` (it must have been pushed after the replication rule existed, and Region B's repository must have been created first). (2) Does the replica secret exist? `aws secretsmanager describe-secret --region us-west-2 --secret-id <secret name>`. (3) Task logs: `aws logs tail /ecs/product-service-b --region us-west-2`.

**`/products` returns 500 but `/health` returns 200.** The schema is not loaded: run the one-off migration task ([runbook.md](runbook.md)).

**A rotation stays `AWSPENDING` after about 5 minutes.**
1. Check for the livelock: `aws rds describe-events --source-type db-cluster --source-identifier <cluster> --duration 30`. Repeated "Reset master credentials" events mean the function is asking RDS again on every retry (fixed in the current function).
2. Check the cluster: `aws rds describe-db-clusters ... --query 'DBClusters[0].[Status,PendingModifiedValues]'`. If it is `available` with no pending change, the database already holds the new password.
3. **Finish it by hand** (this is what the last step does; reversible by moving the label back):
   ```bash
   aws secretsmanager update-secret-version-stage --secret-id <name> --version-stage AWSCURRENT \
     --move-to-version-id <pending version id> --remove-from-version-id <current version id>
   aws secretsmanager update-secret-version-stage --secret-id <name> --version-stage AWSPENDING \
     --remove-from-version-id <that same pending version id>      # tidy the leftover label
   ```
4. Prove a **new** connection works (running tasks hold older connections and prove nothing): run the one-off migration task and check it exits 0.

**Reads fail for about 30 s on a switchover.** Check which endpoint the app uses (`DB_HOST` in the task definition). A cluster (writer) endpoint stops serving on a demoted cluster; a **reader** endpoint is the right one for a read-only app.

**The main name does not fail over to Region B.** (1) Does the SECONDARY record exist (`enable_failover_record`), with its own set identifier? (2) Is Region B healthy on its own name? (3) Look at both signals: the load balancer's target health (the alias's `evaluate_target_health`, fast) and the alarm-driven health check (`aws cloudwatch describe-alarms`, `AWS/Route53 HealthCheckStatus`, about 4 to 5 minutes). (4) Remember DNS caching: alias records are answered with a 60-second lifetime.

**HTTPS shows a certificate error after a failover.** Region B's certificate must list the main name as an alternative name (it does when `failover_domain` is set); check `openssl s_client -connect <name>:443 -servername <name>` and look at the subject alternative names.

**`terraform plan` in the Region B stack cannot read outputs.** The main stack must be applied first with `enable_aurora`, `enable_dr_replica`; the outputs it reads (`global_cluster_id`, `global_cluster_engine_version`, `db_secret_name`) are empty otherwise.

**A destroy stops with `ResourceInUse` on the green target group.** Plan and destroy again ([Deployment.md](Deployment.md), section 7); the listener that pointed at it is gone by then.

**After any switchover or failover, do not run Terraform** until the global cluster's writer is Region A again (`aws rds describe-global-clusters`): Terraform expects Region A to be the writer.

## 5. What is still unproven

- **The alarm-driven failover path** (Drill 4b), the one meant for a whole-Region outage.
- **The database failover with data loss allowed** (Drill 5): the real recovery time and any data loss.
- **A switchover without a read gap** (needs the reader endpoint in Region A, then a re-test).
- **The cause of Region B's 500s after a switch back**, and the lag metric's first-minute spike.
- **The ACU the primary actually used under write load.**
- **The scheduled 7-day rotation** (only manual rotations were run).
- **A real Region outage:** nothing here can simulate one; the drills stop services or move roles, which is the closest available.
