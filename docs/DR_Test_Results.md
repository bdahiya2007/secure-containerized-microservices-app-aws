# Disaster recovery: what was built, what the drills showed, what went wrong, and how to troubleshoot

**Status: one paid session on 2026-11-07, partly written up.** Drills 1 to 4b are recorded below, with the CloudWatch evidence for 4b. **Drill 5 (the database failover) is pending and marked as such.** Everything here is measured from the live session unless it says "hypothesis". Costs are estimates; Cost Explorer lags by many hours.

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
| 4b. The alarm path (Region A kept down 9 minutes) | **Passed, with a correction to the design's assumptions.** Three separate signals fired at very different times: Region B answered at **+42 s**, the Route 53 health check went unhealthy at about **+4.5 to 5.5 min**, and the CloudWatch **alarm state** changed only at **+8 min 41 s**. Route 53 follows the metric's data, not the alarm's state |
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
- **Surprise:** the **CloudWatch alarm stayed `OK` and the Route 53 health check stayed healthy** for the whole outage, yet the name failed over. Drill 4b confirmed why: the PRIMARY record's alias has `evaluate_target_health` on, and the load balancer's healthy-target count had no data from 22:51, so Route 53 failed over within about a minute. The alarm-driven path needed several more minutes and was restored before it could trip, so this drill did **not** exercise it; Drill 4b did.

### Drill 4b: the alarm path
The same outage, but Region A's service was kept at zero tasks for 9 minutes so the alarm-driven path could trip (autoscaling minimum set to 0 first, service to 0 at **22:51:34 UTC**, restored at **23:00:50**).

**Timeline, from the CloudWatch data (UTC; seconds are after the service was stopped)**

| Time | Seconds | What |
|---|---|---|
| 22:51:34 | 0 | Region A's service set to zero tasks |
| 22:52:00 | | The service's `RunningTaskCount` reports **0**: its **last datapoint**. No data at all after this until the restore |
| 22:52:18 | **+42 s** | The main name is answered by **Region B** (HTTPS valid): the load balancer's own health, through the alias's `evaluate_target_health` |
| 22:56 | about **+4.5 to 5.5 min** | The **Route 53 health check** (which follows the alarm's metric) turns **unhealthy** (its status metric drops to 0) |
| 23:00:15 | **+8 min 41 s** | The **alarm state** changes `OK` to `ALARM` |
| 23:00:50 | | Region A's service restored to 2 tasks |
| 23:02:00 | | Two tasks running again (the metric reports 2) |
| 23:03:15 | restore + 2 min 25 s | The alarm changes `ALARM` to `OK` |
| 23:03:57 | | The main name is answered by Region A again |
| 23:04 | | The Route 53 health check reports healthy again |

**The alarm's state history, as CloudWatch recorded it** (`describe-alarm-history`; the alarm watches `RunningTaskCount` below 1, minimum statistic, 3 of 3 one-minute periods, missing data treated as breaching):

| UTC | Change | CloudWatch's stated reason |
|---|---|---|
| 20:59:15 | `INSUFFICIENT_DATA` to `OK` | 3 of the last 3 datapoints were 2.0, not less than the threshold (the alarm was new) |
| **23:00:15** | **`OK` to `ALARM`** | "1 out of the last 3 datapoints [0.0 (22:52:00)] was less than the threshold (1.0) and **2 missing datapoints were treated as [Breaching]**" |
| **23:03:15** | **`ALARM` to `OK`** | "1 out of the last 3 datapoints [2.0 (23:02:00)] was not less than the threshold (1.0) and 1 missing datapoint was treated as [Breaching]" |

**The raw per-minute data** (UTC; "no data" means CloudWatch holds no datapoint for that minute):

| Minute | Running tasks (min) | Route 53 health check (1 healthy) | Healthy targets (Region A, blue group) |
|---|---|---|---|
| 22:44 | 2 | 1 | 2 |
| 22:45 | 2 | 1 | 2 |
| 22:46 | 2 | 1 | 2 |
| 22:47 | 2 | 1 | 2 |
| 22:48 | 2 | 1 | 2 |
| 22:49 | 2 | 1 | 2 |
| 22:50 | 2 | 1 | 2 |
| 22:51 | 2 | 1 | no data |
| 22:52 | 0 | 1 | no data |
| 22:53 | no data | 1 | no data |
| 22:54 | no data | 1 | no data |
| 22:55 | no data | 1 | no data |
| 22:56 | no data | 0 | no data |
| 22:57 | no data | 0 | no data |
| 22:58 | no data | 0 | no data |
| 22:59 | no data | 0 | no data |
| 23:00 | no data | 0 | no data |
| 23:01 | 0 | 0 | 2 |
| 23:02 | 2 | 0 | 2 |
| 23:03 | 2 | 0 | 2 |
| 23:04 | 2 | 1 | 2 |
| 23:05 | 2 | 1 | 2 |
| 23:06 | 2 | 1 | no data |

![Running tasks in Region A's service, with the alarm threshold and the key events marked](images/dr-4b-running-tasks.png)

*The metric the alarm watches: 2 tasks, then 0 at 22:52, then no data until the restore. The dashed lines mark the events in the table above; their labels are cut off at the edge of the chart, so use the table for exact times.*

![Route 53 health check status](images/dr-4b-route53-health.png)

*The health check turned unhealthy at 22:56, about four minutes before the alarm's state changed, and healthy again at 23:04.*

![Healthy targets behind Region A's load balancer](images/dr-4b-healthy-targets.png)

*The load balancer's healthy-target count has no data from 22:51 until 23:01. This is the signal behind the +42 s failover.*

**Reading it**
- **There were three layers, at very different speeds.** (1) The alias's target-health evaluation moved traffic in **42 seconds**. (2) The Route 53 health check, which follows the alarm's **metric stream**, turned unhealthy after about **5 minutes**. (3) The CloudWatch **alarm state** took **8 minutes 41 seconds**.
- **Route 53 does not use the alarm's state.** The health check went unhealthy while the alarm was still `OK`, which matches AWS's own note that Route 53 monitors the metric's data stream, not the alarm. With no data, it counts the check as unhealthy (the setting chosen in the design).
- **Why the alarm state is slow (hypothesis, not confirmed):** after the last datapoint at 22:52 the metric stopped reporting; CloudWatch's own reason at 23:00:15 still shows the window as "one real datapoint and two missing", which is a window about six minutes old, so it appears to evaluate missing data with a lag of several minutes. My earlier estimate of "3 to 4 minutes" for the alarm was wrong.
- **What the design gets from each layer:** the alias's evaluation protects users in the first minute when the load balancer is up but its targets are gone. The alarm-fed health check is the backstop for a whole-Region or load-balancer outage, where the load balancer's own health data would not be available; it needs about 5 minutes. The alarm's own state drives nothing else here: no notification is attached to it.
- **Probe on the main name: 408 requests, 16 failed, the longest run 14 (about 28 s).** All 16 failures were **503s from Region A's load balancer**, between 22:51:49 and 22:52:27: its targets were gone, and DNS answers still pointed at Region A for part of that window (alias answers live 60 seconds; the last failure was 9 seconds after the first Region B answer).
- **Restore:** both tasks were running again within about a minute, the alarm returned to `OK` 2 minutes 25 seconds after the restore command, and Region A answered the main name again after about 3 minutes.

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
| 11 | The alarm's state changed 8 min 41 s after the outage, later than the Route 53 health check | The alarm showed `OK` for 8 minutes while its metric had no data and the health check was already unhealthy | Route 53 reads the metric's data stream, not the alarm state (AWS documents this); CloudWatch evaluates missing data with a lag of several minutes (hypothesis) | None needed: the failover does not wait for the alarm state. Documented; the design doc's estimate of 3 to 4 minutes was wrong | Understood |

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

**The alarm still says `OK` minutes after the service stopped.** That is expected: CloudWatch evaluates a metric that has stopped reporting with a lag (8 min 41 s observed). Check the Route 53 health check instead (`AWS/Route53` `HealthCheckStatus`, 1 healthy / 0 unhealthy), which follows the metric's data stream and turned unhealthy after about 5 minutes; and the load balancer's `HealthyHostCount`, which drives the alias failover in about a minute. Do not rely on the alarm state to see a failover coming.

**HTTPS shows a certificate error after a failover.** Region B's certificate must list the main name as an alternative name (it does when `failover_domain` is set); check `openssl s_client -connect <name>:443 -servername <name>` and look at the subject alternative names.

**`terraform plan` in the Region B stack cannot read outputs.** The main stack must be applied first with `enable_aurora`, `enable_dr_replica`; the outputs it reads (`global_cluster_id`, `global_cluster_engine_version`, `db_secret_name`) are empty otherwise.

**A destroy stops with `ResourceInUse` on the green target group.** Plan and destroy again ([Deployment.md](Deployment.md), section 7); the listener that pointed at it is gone by then.

**After any switchover or failover, do not run Terraform** until the global cluster's writer is Region A again (`aws rds describe-global-clusters`): Terraform expects Region A to be the writer.

## 5. What is still unproven

- **A failover where the load balancer's own health data is unavailable** (a real Region or load balancer outage): Drill 4b exercised the alarm-fed health check but the alias's target health still worked.
- **The database failover with data loss allowed** (Drill 5): the real recovery time and any data loss.
- **A switchover without a read gap** (needs the reader endpoint in Region A, then a re-test).
- **The cause of Region B's 500s after a switch back**, and the lag metric's first-minute spike.
- **The ACU the primary actually used under write load.**
- **The scheduled 7-day rotation** (only manual rotations were run).
- **A real Region outage:** nothing here can simulate one; the drills stop services or move roles, which is the closest available.
