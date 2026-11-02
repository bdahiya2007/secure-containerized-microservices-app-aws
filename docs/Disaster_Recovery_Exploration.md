# Disaster recovery with Aurora Global Database: exploration (Step 1)

**Status: design exploration only. Nothing in this page is built or deployed.** It answers "Step 1: explore Aurora Serverless v2 and Aurora Global Database" and proposes what "Step 2: update the architecture" should be. Facts below were read from the AWS documentation on 2026-11-01 (sources at the end). Costs are **estimates from list prices**, not measured. Where something could not be confirmed, it says so.

## The goal

Survive the loss of a whole AWS Region (us-east-1) with a small, cheap second Region and a documented recovery. The chosen shape is **pilot light**:

| | Region A (us-east-1, primary) | Region B (us-west-2, recovery) |
|---|---|---|
| Traffic | All of it | None until a failover |
| Containers | Full service (2 to 4 Fargate tasks) | **1 small task** kept running, scaled up in a disaster |
| Database | Aurora PostgreSQL, Serverless v2, **writer** | Aurora PostgreSQL, Serverless v2, **read-only secondary** in the same global database |
| DNS | `products.example.com` points here while healthy | Route 53 failover record points here when A is unhealthy |

(`example.com` stands for your own domain; the real name is kept out of this public repository.)

## Step 1a: what Aurora Serverless v2 is, and what matters for us

- **Capacity is measured in ACUs** (about 2 GiB of memory each) and scales up and down by itself between a minimum and a maximum you set. You pay per ACU-hour, so an idle database costs the minimum, not a fixed instance.
- **It can scale to zero and pause** (minimum 0 ACU), which would make an idle database almost free. **That does not help us:** the primary of a global database does not auto-pause, and **neither do the secondary clusters** ([auto-pause page](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2-auto-pause.html)). So both clusters run all the time, at 0.5 ACU at the lowest.
- **Global Database lifts the floor further.** AWS recommends a minimum of **8 ACU for the primary** cluster of a global database (the recommendation applies to the primary only and is "subject to change"), and notes that Global Database is one of the features that stops an idle instance reaching its minimum ([capacity page](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2.setting-capacity.html)). At list price 8 ACU is about $0.96 an hour, so a demo should run lower and accept the risk of replication lag under write load. This is the biggest cost lever and must be tested, not assumed.
- **Versions:** Aurora PostgreSQL **18.3 and higher supports both Serverless v2 and Global Database in us-east-1 and us-west-2**, so the move can keep PostgreSQL 18 (the project uses 18.6 on RDS today) ([Global Database](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Concepts.Aurora_Fea_Regions_DB-eng.Feature.GlobalDatabase.html), [Serverless v2](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Concepts.Aurora_Fea_Regions_DB-eng.Feature.ServerlessV2.html)). The two Regions must run the same major and minor version for managed switchover and failover.

## Step 1b: what Aurora Global Database is

One **primary** cluster takes writes. Up to 10 **secondary** clusters in other Regions are read-only copies, kept in step by Aurora's storage layer (not by the database engine), with latency typically under a second. A **global writer endpoint** always points at the current primary.

| Topic | What the documentation says |
|---|---|
| **RPO** (data you can lose) | Failover after an unplanned outage: "typically a non-zero value measured in seconds", depending on replication lag at the moment of failure. Planned **switchover**: 0, because Aurora waits for the secondary to catch up first |
| **RTO** (time to recover) | "In the order of minutes". A managed failover typically has the secondary take over "within a few minutes". On Aurora PostgreSQL 16.8 and later, a switchover is typically under 30 seconds for reads and writes |
| **Failover types** | **Managed failover** (`failover-global-cluster --allow-data-loss`): the recommended disaster path; the old primary is added back as a secondary when its Region returns. **Manual**: detach the secondary and promote it; only when versions are incompatible |
| **Unplanned-failover side effects** | Aurora takes a snapshot of the old primary's volume at the point of failure (when it can), so unreplicated writes can be recovered. Write fencing is best effort, so a short **split-brain** is possible. After promotion the other secondaries are rebuilt, which can take minutes to hours |
| **RPO control** | `rds.global_db_rpo` (20 s and up) blocks commits on the primary when every secondary is behind. For two Regions AWS recommends leaving it at the default on the secondary so a failover is not blocked. We would **monitor** `AuroraGlobalDBRPOLag` instead |
| **Not supported** | Backtrack; Aurora Auto Scaling of secondary clusters; stopping or starting one cluster of the global database; cluster cache management on secondaries; automatic minor version upgrades |

### The finding that changes our design: Secrets Manager

The documentation states: **"Secrets Manager doesn't support Aurora Global Database. When you add a Region to a global database, you must first turn off Secrets Manager integration for the DB instance."**

Our stack depends on exactly that integration: `manage_master_user_password = true`, with RDS creating and rotating the password and the app reading the secret at runtime ([Secrets.md](Secrets.md)). That cannot be carried over unchanged. Options for Step 2:

| Option | How | Trade-off |
|---|---|---|
| **A (recommended to evaluate): self-managed secret, replicated** | Create the secret ourselves in Secrets Manager in Region A with a **replica in Region B**; set the cluster password from a write-only or generated value that never reaches Terraform state (to confirm in the AWS provider); rotate it with a Secrets Manager rotation function | Keeps the runtime-read design and the task role's single `GetSecretValue` permission. We own the rotation Lambda, which is new code and a new thing to test |
| B: a separate application user | Keep a master secret for admin only; the app uses its own database user whose secret we rotate | More moving parts; same rotation work |
| C: drop rotation | Static password in a replicated secret | Weakest; gives up a tested feature, so not recommended |

The app code should not need to change: it already takes the secret ARN from `DB_SECRET_ARN` and retries once after a failed login. The task in Region B would get the **replica's** ARN.

## Step 1c: proposed architecture (Step 2 target)

```
                     Route 53: products.example.com  (failover routing, TTL 60 s)
                        |  primary (healthy)                |  secondary (if A unhealthy)
                        v                                   v
        +------------- us-east-1 -------------+   +------------ us-west-2 ------------+
        | ALB -> ECS Fargate (2 to 4 tasks)    |   | ALB -> ECS Fargate (1 task)       |
        | Aurora Serverless v2  WRITER  -------+--->  Aurora Serverless v2  READ-ONLY   |
        | secret (primary)  ------------------+--->  secret (replica)                  |
        | ECR (images)  ----------------------+--->  ECR (replicated images)           |
        +--------------------------------------+   +-----------------------------------+
                  Aurora global writer endpoint follows the primary after a failover
```

What Region B needs, each of which is a Terraform resource or group:

- **Network:** its own VPC, private and public subnets in two zones, an ALB, security groups with the same rules as Region A, and a way out for the tasks (NAT gateway, or VPC endpoints for ECR, Secrets Manager and CloudWatch Logs).
- **Compute:** an ECS cluster and a one-task Fargate service with the same task definition shape, reading the **replica** secret and the **Region B** Aurora endpoint.
- **Images:** ECR **cross-Region replication** (or a push to both) so the recovery Region can always pull the current image; today's pipeline deploys to Region A only, so Region B's service must be updated by the pipeline or a documented step.
- **Database:** a global cluster, the primary cluster in A, a secondary cluster in B with its own **KMS key** (encrypted storage needs a key in the secondary Region), and a `db.serverless` instance in each. The data is demo seed data, so the simplest migration is a **new Aurora cluster plus re-running the existing schema task**, not converting the RDS instance in place.
- **DNS and health:** Route 53 failover records with a health check per Region. **Gap to solve:** Region A's ALB admits only the owner's address, so Route 53's health checkers cannot reach it. Either allow Route 53's published health-checker ranges, or use a health check driven by a CloudWatch alarm (for example on healthy hosts in the target group), which needs no public access. The alarm route is preferred.
- **Terraform layout:** keep the current stack and add a Region B stack (a second root with its own state key, or a module with a provider alias). The global cluster and both Aurora clusters need both Regions, so they need a provider alias in one place. Decide in Step 2.

## Recovery runbook outline (to be written and tested in Step 2)

1. **Detect:** the Route 53 health check fails, or a person decides. Check `AuroraGlobalDBRPOLag` to see how much data a failover would lose.
2. **Fail over the database:** `aws rds failover-global-cluster ... --allow-data-loss` toward Region B. Wait for the Region B writer.
3. **Scale Region B:** raise the ECS service from 1 task to the normal count; raise the Aurora maximum capacity if needed.
4. **Traffic:** Route 53 moves the name by itself when the health check fails; for a manual decision, flip the record. Keep the TTL at 60 seconds.
5. **Verify:** `/health`, `/products`, and that writes land on the new primary.
6. **Fail back:** when Region A is healthy again, a **switchover** (RPO 0) returns the primary, then scale Region B down again.

## Targets, with the reasoning

| Target | Proposed | Why |
|---|---|---|
| RPO | about **1 minute**, measured with `AuroraGlobalDBRPOLag` | AWS says "seconds" for failover; one minute leaves margin, and we do not set `rds.global_db_rpo` |
| RTO | **30 minutes or less** | Rough parts: detection 2 to 3 minutes, database failover a few minutes, ECS scale-up 2 to 3 minutes, DNS 1 minute. This is an estimate to be measured in the Step 2 drill |
| Failover | **Manual and documented** | Automation (Route 53 Application Recovery Controller, or Lambda and Step Functions as in AWS's prescriptive guidance) adds cost and a risk of a wrong automatic failover; revisit later |

## Estimated cost (list prices, us-east-1; Region B assumed the same, unconfirmed)

| Item | Per hour | Per day | Notes |
|---|---|---|---|
| Today's stack (Region A, RDS `db.t4g.micro`) | about $0.14 to $0.16 | about $3.50 | Measured; includes NAT, ALB, two tasks, RDS |
| Aurora primary at 0.5 to 1 ACU | $0.06 to $0.12 | $1.44 to $2.88 | $0.12 per ACU-hour; replaces the RDS instance. At AWS's recommended 8 ACU: $0.96 an hour, about $23 a day |
| Aurora secondary at 0.5 ACU | $0.06 | $1.44 | Cannot pause, so it always runs |
| Region B network and compute | about $0.08 | about $1.90 | NAT gateway $0.045, ALB about $0.023, one 0.25 vCPU task about $0.012 |
| Storage, replicated writes, transfer | cents | cents | $0.10 per GB-month; replicated write I/O $0.20 per million; cross-Region transfer $0.02 per GB |
| **Estimated total (low settings)** | **about $0.30** | **about $7** | About double today's stack. Not tested |

Because one cluster of a global database cannot be stopped on its own, **the only way to stop the cost is to destroy the whole thing**. Plan to build, test, record the evidence and tear down in one session, as with the earlier tests. A $5 budget is not enough for a day of this.

## Open questions and risks for Step 2

- Can the primary run at 0.5 to 1 ACU without replication lag under a load test? (AWS recommends 8.)
- Secondary readers: AWS says readers in promotion tiers 2 to 15 scale independently and can lag if the minimum is low. Which tier should the secondary instance use, and what does it cost?
- Terraform details to confirm in the pinned AWS provider: the global cluster and secondary arguments, a write-only master password, and the destroy order (secondary before global cluster).
- The Secrets Manager rotation function (option A): the permissions it needs, and a test that a rotation does not break the running tasks (as in the earlier rotation tests).
- ALB health check without opening the ALB to the internet (alarm-based Route 53 health check).
- HTTPS: the load balancer serves HTTP only today. A real failover name needs a certificate in **both** Regions (ACM, DNS validation); optional for a demo.
- The deployment pipeline updates Region A only; decide how Region B's service gets new images.
- Region B's service starts with the database read-only. `GET /products` only reads, so it should serve; confirm in the drill.

## Proposed Step 2 test plan

1. Build the global database and Region B; apply and verify with the existing `verify-deployment.sh` extended for both Regions.
2. **Switchover** to Region B (RPO 0) and back; time the gap with a request probe.
3. **Failover drill:** make Region A's health check fail (for example, scale the Region A service to zero), run the managed failover with `--allow-data-loss`, scale Region B, and measure real RTO and RPO from CloudWatch.
4. Record the evidence as in [Rollback_Test.md](Rollback_Test.md), then tear everything down.

## Sources (AWS documentation, read 2026-11-01)

- [Using Amazon Aurora Global Database](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-global-database.html) (overview and limitations, including Secrets Manager)
- [Configuration requirements of an Aurora global database](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-global-database.configuration.requirements.html)
- [Using switchover or failover in Aurora Global Database](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-global-database-disaster-recovery.html)
- [Supported Regions and DB engines for global databases](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Concepts.Aurora_Fea_Regions_DB-eng.Feature.GlobalDatabase.html)
- [Supported Regions and DB engines for Aurora Serverless](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/Concepts.Aurora_Fea_Regions_DB-eng.Feature.ServerlessV2.html)
- [Performance and scaling for Aurora Serverless](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2.setting-capacity.html)
- [Scaling to zero ACUs with automatic pause and resume](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/aurora-serverless-v2-auto-pause.html)
- [Aurora pricing](https://aws.amazon.com/rds/aurora/pricing/) (figures taken from its worked examples; confirm on the pricing calculator)
