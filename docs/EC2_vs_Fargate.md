# EC2 vs Fargate for Amazon ECS: differences, when to use which, and the trade-offs

Amazon ECS runs containers on one of two kinds of compute: **EC2** (virtual machines you run and ECS places containers on) or **Fargate** (AWS runs the compute and you only describe the task). This page compares them and explains why this project uses Fargate. For what the Fargate choice looks like in this repository, see [Architecture.md](Architecture.md#fargate-instead-of-ec2-what-differs).

Prices and limits below are from AWS's published figures for us-east-1 at the time of writing and are approximate. Check the current pricing pages before deciding anything that depends on them.

## In one paragraph

Fargate trades some money and some flexibility for not having servers to run. EC2 trades operational work for control and, when the machines are kept busy, a lower price per unit of compute. For a small, steady, stateless service with no special hardware needs, Fargate is usually the better default. EC2 starts to win when the fleet is large and well packed, when you need hardware or host features Fargate does not offer, or when image start-up time and host-level tuning matter.

## What you manage

| | EC2 launch type | Fargate |
|---|---|---|
| **Servers** | You: choose instance types, an AMI, run an Auto Scaling group and a launch template | AWS. There are no instances to see, patch or scale |
| **OS and agent patching** | You (AMI refresh, ECS agent and Docker updates, rolling replacement of instances) | AWS |
| **Capacity planning** | You keep enough instances for the tasks you want, then scale tasks (two layers: tasks and the cluster) | Only tasks. Capacity appears when a task starts |
| **Task sizing** | CPU and memory per container; many tasks share an instance | CPU and memory for the whole task, from fixed combinations (for example 0.25 vCPU with 0.5 to 2 GB, up to 16 vCPU and 120 GB); each task gets its own isolated compute |
| **Networking** | `awsvpc`, `bridge` or `host` mode | `awsvpc` only: each task gets its own network interface and security group |
| **Security boundary** | Containers on a host share its kernel with each other | Each task runs in its own isolated environment, with no shared kernel between tasks |
| **Host access** | SSH, host volumes, privileged containers, Docker socket, daemon-style tasks | None. No SSH, no host mounts, no privileged mode |
| **Hardware** | Any instance family: GPUs and accelerators, very large memory, local NVMe, specific CPU features | x86 and Graviton (ARM) in fixed sizes; no GPUs |
| **Storage** | Instance store, EBS, EFS, host paths | Ephemeral task storage (20 GiB by default, up to 200 GiB), EFS, and EBS attached to a task; no host paths |
| **Image pulls** | Layers are cached on the instance, so a second task of the same image starts quickly | Each new task pulls the image onto fresh compute, so start-up is slower unless the image is small or uses lazy loading |
| **IAM** | An instance role on every instance plus task roles | Task execution role and task role only |
| **Spot (discounts for interruptible work)** | Yes | Yes (Fargate Spot, for tasks that tolerate interruption) |

## Cost

- **Fargate** bills per second (one-minute minimum) for the vCPU and memory a task requests, whether or not the task uses them. In us-east-1 on Linux x86 that is roughly $0.040 per vCPU-hour and $0.0044 per GB-hour. One 0.25 vCPU, 512 MB task costs about $0.012 an hour.
- **EC2** bills for each instance for as long as it runs, whether or not tasks fill it. You also pay for the work of running them.

An illustration (approximate, on-demand): 1 vCPU with 2 GB costs about $0.05 an hour on Fargate. A `t3.small` (2 vCPU, 2 GB) is about $0.02 an hour. If two such tasks can share that instance, EC2 is under half the price per task. If the instance is mostly idle, or you can only fit one task, the gap shrinks or reverses.

What decides it:

- **Utilisation.** EC2 is cheaper only when the instances are kept well packed. Idle capacity is paid for.
- **Commitments.** Savings Plans and Reserved Instances reduce the price of both, and a Compute Savings Plan applies to Fargate too.
- **Operations time.** Patching, replacing instances and tuning capacity cost engineering hours that do not show on the AWS bill.
- **Spot.** Both can use spot capacity for interruptible work.
- **Everything else on the bill.** In this project one running stack costs about $0.16 to $0.20 an hour; the two Fargate tasks are about $0.025 of it. The NAT gateway, load balancer and database dominate, so the compute choice barely moves the total.

## Trade-offs

### Fargate

**Strengths**
- No servers to patch, scale or secure. Less to get wrong, and less on an audit checklist.
- Strong isolation between tasks, and a smaller attack surface (no host to log in to).
- Scales by adding tasks only, with no cluster capacity to plan.
- You pay for tasks that exist, so small and spiky workloads cost little.
- Simple IAM: no instance role, and the roles are per task.

**Weaknesses**
- A higher price per unit of compute when EC2 would be well packed.
- Fixed CPU and memory combinations. A task that needs 1 vCPU and 3 GB may have to take a larger size.
- Slower start for new tasks (a fresh image pull each time), which matters for fast scale-out.
- No GPUs, no privileged mode, no host access, no daemon-style tasks, and fewer low-level tuning options.
- Less visibility: you cannot inspect the host when something odd happens (ECS Exec reaches the container only).
- Per-task network interfaces use up IP addresses in the subnet, so subnets must be sized for the task count.

### EC2

**Strengths**
- Lower cost per unit of compute at scale when well packed, and the most pricing options.
- Full control: instance type, AMI, kernel settings, GPUs and accelerators, local disks, privileged and host-network containers, daemon tasks on every node.
- Warm instances with cached images start new tasks quickly.
- Large or unusual shapes (very large memory, many tasks per host).

**Weaknesses**
- You run the fleet: patching, AMIs, agent updates, replacing unhealthy instances, draining before updates, and capacity planning with two scaling layers.
- Idle or fragmented capacity is paid for.
- Containers on one host share a kernel, so isolation is weaker, and a compromised container has a nearer path to the host.
- More moving parts (launch template, Auto Scaling group, capacity provider, instance profile), more to configure and secure.

## When to use which

**Choose Fargate when:**
- The service is stateless and the team is small, or time is better spent on the application than on servers.
- Load is variable or small, so paying per task beats paying for idle instances.
- Strong task isolation and a minimal host attack surface matter (regulated or security-sensitive workloads).
- You have no need for GPUs, privileged containers or host access.
- You are starting out. It is easy to begin on Fargate and move later if the numbers justify it.

**Choose EC2 when:**
- You need GPUs or accelerators, a very large instance, local NVMe, or a specific instance family.
- The fleet is large and steady enough to keep instances well packed, so the saving is real and worth the work.
- You need host-level features: privileged containers, host networking, daemon tasks, a custom kernel or OS.
- Start-up latency is critical and you can keep warm, image-cached capacity.
- You already operate a fleet and the tooling for it.

**A mix is common.** An ECS cluster can have both (and Fargate itself can be split between on-demand and Spot; see [Fargate_Spot.md](Fargate_Spot.md)): for example Fargate for the web tier and EC2 (or Fargate Spot) for batch or GPU work, using capacity providers to split the load.

## Why this project uses Fargate

- It is a small, stateless Node.js service behind a load balancer, with 2 to 4 tasks, so a fleet would sit mostly idle.
- Security is a goal: no instance role or host to defend, isolated tasks, a read-only root filesystem, non-root user and no ECS Exec. See [Architecture.md](Architecture.md#5-defense-in-depth).
- There is no need for special hardware or host access.
- The compute is a small part of the cost, so the EC2 saving would be small.
- Less to operate: no AMIs, no patching and one scaling layer.

**What would change my mind:** a sustained load large enough to pack instances (roughly dozens of tasks around the clock), a need for GPUs or host features, or scale-out that must start faster than image pulls allow.

## If you switch to EC2 later

In Terraform you would add a launch template and an Auto Scaling group using an ECS-optimised AMI, an instance role and profile, and an ECS capacity provider linked to the group. The task definition would change from `["FARGATE"]` to `["EC2"]` and could keep `awsvpc`, and the service would use the capacity provider instead of `launch_type = "FARGATE"`. You would need to size and patch the instances and scale them as well as the tasks. The application, image, load balancer, database and CodeDeploy blue/green setup stay the same. The `verify-deployment.sh` Fargate checks would need to be replaced.
