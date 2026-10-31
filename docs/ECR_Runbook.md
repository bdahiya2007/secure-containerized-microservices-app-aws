# ECR runbook: create the repository and push the Product Service image

This runbook covers the Amazon ECR part of the project: creating the `product-service` repository with Terraform, then logging Docker in to ECR, and building, tagging and pushing the
image by hand. The steps are in the order they were run. Each one says what the command does and shows an example of what to expect.

All commands run from the **repository root** (`secure-containerized-microservices-app-aws/`). Your 12-digit AWS account ID is written as `ACCOUNT_ID` below; never commit the real value.

## What this does and does not need

| Needed | Notes |
|---|---|
| `product-service/` with the `Dockerfile`, `package.json`, `package-lock.json` and `src/` | Already in the repository |
| Docker running | `docker version` should show a client and a server |
| AWS CLI v2 with working credentials | Check with step 1. SSO sessions expire; run `aws sso login` if a command reports an expired token. |
| Terraform >= 1.5 | For step 2 |
| IAM permissions for ECR | Create repository and lifecycle policy (`ecr:CreateRepository`, `ecr:PutLifecyclePolicy`, plus read actions), and push (`ecr:GetAuthorizationToken`, `ecr:BatchCheckLayerAvailability`, `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`, `ecr:PutImage`) |

You do **not** need the database, VPC, ECS, ALB or any other AWS resource to build and push. Those come later with a full `terraform apply`.

## Step 1: Set variables and check your credentials

```bash
export AWS_REGION=us-east-1
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$AWS_REGION")
REGISTRY="$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
REPO_URI="$REGISTRY/product-service"
echo "$REPO_URI"
```

| Part | What it does |
|---|---|
| `export AWS_REGION=us-east-1` | Sets the region once, so every later command targets the same place. It must match Terraform's `aws_region` variable (default `us-east-1`). |
| `aws sts get-caller-identity --query Account --output text` | Asks AWS who you are and prints only the account ID. This also proves your credentials work. |
| `REGISTRY=...` | Builds the private registry host name: `<account>.dkr.ecr.<region>.amazonaws.com`. Every account and region has one. |
| `REPO_URI=...` | Adds the repository name to make the full image location. |

**Example output:**
```
ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/product-service
```

If the shell is restarted later, set these four variables again before continuing.

## Step 2: Create the ECR repository with Terraform

The repository is defined in `terraform/ecr.tf`. Only the repository and its lifecycle policy are created here, because a full `terraform apply` would also build the NAT gateway, load balancer,
database and the rest, which cost about $0.14 an hour.

```bash
terraform -chdir=terraform init
```
Downloads the AWS provider plugin and prepares the working directory. `-chdir=terraform` runs Terraform in that folder without changing your directory.

**Example output (end):**
```
Terraform has been successfully initialized!
```

```bash
terraform -chdir=terraform plan \
  -target=aws_ecr_repository.app -target=aws_ecr_lifecycle_policy.app -out=ecr.tfplan
```
`alb_ingress_cidr` is a required variable, so Terraform will ask for it (or fail with "No value for required variable") even though the ECR repository doesn't use it. Put it in `terraform/demo.auto.tfvars`
([Logging_Runbook.md](Logging_Runbook.md#step-0-set-variables)), or add `-var="alb_ingress_cidr=<your-ip>/32"` to this command.

| Option | What it does |
|---|---|
| `plan` | Shows what Terraform would create, without changing anything |
| `-target=aws_ecr_repository.app` and `-target=aws_ecr_lifecycle_policy.app` | Limits the plan to those two resources. Terraform warns that targeting isn't for routine use; that warning is expected here. |
| `-out=ecr.tfplan` | Saves the plan to a file so `apply` runs exactly what you reviewed. The name ends in `.tfplan` so `.gitignore` excludes it (saved plans can contain sensitive values). |

**Example output:** check that it ends with exactly this.
```
Plan: 2 to add, 0 to change, 0 to destroy.
```
It lists the repository `product-service` (mutable tags, scan on push, AES-256 encryption) and a lifecycle policy that keeps the last 10 images. If the plan shows anything else, stop.

```bash
terraform -chdir=terraform apply ecr.tfplan
```
Applies the saved plan. Because it is a saved plan there is no `yes` prompt.

**Example output:**
```
aws_ecr_repository.app: Creation complete after 1s [id=product-service]
aws_ecr_lifecycle_policy.app: Creation complete after 0s [id=product-service]
Apply complete! Resources: 2 added, 0 changed, 0 destroyed.

Outputs:
ecr_repository_url = "ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/product-service"
```
The "Applied changes may be incomplete" warning is the expected `-target` warning. **Do not run a plain `terraform plan` yet**: it would list the rest of the stack as "to add".
This apply also creates a local state file, `terraform/terraform.tfstate`, which is git-ignored and must not be committed.

## Step 3: Confirm the repository exists

```bash
aws ecr describe-repositories --region "$AWS_REGION" --repository-names product-service \
  --query 'repositories[0].{name:repositoryName,mutability:imageTagMutability,scanOnPush:imageScanningConfiguration.scanOnPush}' --output table
```

| Option | What it does |
|---|---|
| `describe-repositories --repository-names product-service` | Looks up that one repository in AWS (a check that doesn't rely on Terraform's state) |
| `--query '...'` | Keeps only three fields, using a JMESPath expression |
| `--output table` | Prints a readable table |

**Example output:**
```
-------------------------------------------------
|             DescribeRepositories              |
+------------+-------------------+--------------+
| mutability |       name        | scanOnPush   |
+------------+-------------------+--------------+
|  MUTABLE   |  product-service  |  True        |
+------------+-------------------+--------------+
```
`MUTABLE` means a tag such as `latest` can be overwritten by a later push. `scanOnPush = True` means ECR scans each pushed image automatically.

## Step 4: Authenticate Docker with ECR

```bash
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"
```

| Part | What it does |
|---|---|
| `aws ecr get-login-password` | Asks ECR for a temporary password (valid 12 hours), based on your AWS credentials |
| `\|` | Passes that password straight into the next command, so it never appears on screen or in your shell history |
| `docker login --username AWS` | Logs Docker in to the registry. The user name is always the literal `AWS`. |
| `--password-stdin "$REGISTRY"` | Reads the password from the pipe and names the registry to log in to |

**Example output:**
```
Login Succeeded
```
Docker may also warn that credentials are stored unencrypted in its config file. That is normal for this setup.

## Step 5: Build the image

```bash
docker build --platform linux/amd64 --tag product-service:latest product-service
```

| Part | What it does |
|---|---|
| `docker build` | Builds an image from a Dockerfile |
| `--platform linux/amd64` | Builds for x86_64, which is what the ECS Fargate task definition uses. This matters on ARM machines such as Apple Silicon. |
| `--tag product-service:latest` | Names the local image `product-service` with the tag `latest` |
| `product-service` (last argument) | The build context: the folder containing the `Dockerfile` and the app |

**Example output (end):**
```
 => => naming to docker.io/library/product-service:latest
```
The first build takes about a minute (it downloads the base images); later builds are mostly cached. The result is about 220 MB on disk and about 56 MB compressed.

## Step 6: Tag the image with the ECR repository URI

```bash
docker tag product-service:latest "$REPO_URI:latest"
```
Gives the same local image a second name that includes the registry address. Docker decides where to push by looking at the name, so without this tag `docker push` would try Docker Hub. It copies no data: both names point at the same image.

**Check it (optional):**
```bash
docker image ls "$REPO_URI"
```
```
REPOSITORY                                              TAG       IMAGE ID       ...
ACCOUNT_ID.dkr.ecr.us-east-1.amazonaws.com/product-service   latest    <same id as the local image>
```

## Step 7: Push the image to ECR

```bash
docker push "$REPO_URI:latest"
```
Uploads the image layers to ECR. Layers already in the repository are skipped, so later pushes are faster.

**Example output (end):**
```
latest: digest: sha256:<64 hex characters> size: <bytes>
```

## Step 8: Verify the push

```bash
aws ecr describe-images --region "$AWS_REGION" --repository-name product-service \
  --query 'imageDetails[].{tags:imageTags,pushed:imagePushedAt,sizeBytes:imageSizeInBytes}' --output table
```
Lists what ECR holds in the repository.

**Example output:** three rows from one push.

| Row | Size | Tag | What it is |
|---|---|---|---|
| 1 | about 1.4 KB | none | A small build-attestation record (provenance metadata) that BuildKit pushes alongside the image |
| 2 | about 56 MB | none | The actual `linux/amd64` image |
| 3 | about 56 MB | `latest` | The index that ties the two together. This is what `docker pull` and ECS use. |

The three rows have almost identical push times, so they come from a single `docker push`. The untagged rows are normal, not leftovers.
Because the lifecycle policy keeps "the last 10 images" with `tagStatus = any`, all three rows count, so about three pushes' worth are retained.

## Step 9 (optional): Check ECR's scan of the pushed image

Scan-on-push is enabled, so ECR scans the image automatically after the push. The results are stored under the **image digest, not under the `latest` tag**, because
`latest` points to the index and the scan belongs to the actual image underneath it. Asking for the results by tag fails with `ScanNotFoundException` (this happened when the runbook was first run).

**9a. Find the digest of the actual image.** It is the manifest of about 56 MB (the tagged index and the 1.4 KB attestation record are the other two rows from step 8):
```bash
IMAGE_DIGEST=$(aws ecr describe-images --region "$AWS_REGION" --repository-name product-service \
  --query "imageDetails[?imageManifestMediaType=='application/vnd.oci.image.manifest.v1+json' && imageSizeInBytes>\`1000000\`].imageDigest | [0]" \
  --output text)
echo "$IMAGE_DIGEST"
```
It prints `sha256:` followed by 64 hex characters. If you pushed more than once, this picks the first match; use the digest from step 8 for a specific push.

**9b. Read the scan results by digest:**
```bash
aws ecr describe-image-scan-findings --region "$AWS_REGION" --repository-name product-service \
  --image-id imageDigest="$IMAGE_DIGEST" \
  --query '{status:imageScanStatus.status,description:imageScanStatus.description,counts:imageScanFindings.findingSeverityCounts}' --output json
```

**Example output (a clean image):**
```json
{
    "status": "COMPLETE",
    "description": "The scan was completed successfully.",
    "counts": {}
}
```
An empty `counts` means no findings. Findings would appear as severities with numbers, for example `"HIGH": 2`. A status of `IN_PROGRESS` means to wait a minute and run it again.
This is ECR's basic scan, which mainly covers operating-system packages, so it can differ from the Trivy results in [vulnerability-scan-report.md](vulnerability-scan-report.md).

**Things to know:**
- **The `scan` column in `describe-images` showed `None`** for all three rows even though the scan had completed, so don't rely on it. Use the findings command above.
- **Manual rescans are limited.** `aws ecr start-image-scan` on the same image within 24 hours fails with `LimitExceededException: The scan quota per image has been exceeded`. That error means an automatic scan already ran; read its results instead.

## Push another version

`latest` is overwritten on every push because the repository has mutable tags. To keep a rollback point, also tag by git SHA:

```bash
TAG=$(git rev-parse --short HEAD)          # needs a git repository
docker tag product-service:latest "$REPO_URI:$TAG"
docker push "$REPO_URI:$TAG"
```
Making ECR tags immutable (`image_tag_mutability = "IMMUTABLE"`) is the remaining Checkov finding. It would reject a second push of `latest`, so it waits for this git SHA tagging.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `The SSO session associated with this profile has expired` or `ExpiredToken` | SSO session ended | `aws sso login`, then retry |
| `AccessDenied` on `terraform apply` or on a push | Your role lacks an ECR permission (see the table at the top) | Use a role with ECR permissions |
| `no basic auth credentials` on `docker push` | Not logged in, or the 12-hour token expired | Repeat step 4 |
| `repository does not exist` or `name unknown` on push | Step 2 was not done, or the repository name or region differs | Run step 3, check `$REPO_URI` and `$AWS_REGION` |
| `An image does not exist locally with the tag` on `docker push` | Step 6 was skipped | Run step 6 |
| `docker: command not found` in WSL | Docker Desktop's WSL integration is off | Docker Desktop, Settings, Resources, WSL integration, enable your distro |
| Variables are empty (`$REPO_URI` prints blank) | The shell was restarted | Repeat step 1 |
| `ScanNotFoundException` from `describe-image-scan-findings --image-id imageTag=latest` | `latest` is an index, and scan results are stored under the image digest | Use the digest (step 9a and 9b) |
| `LimitExceededException: The scan quota per image has been exceeded` on `start-image-scan` | A scan already ran on this image in the last 24 hours | Read the existing results (step 9b) |
| Container fails on ECS with `exec format error` | Image built for the wrong CPU architecture | Rebuild with `--platform linux/amd64` |

## Clean up

The repository costs only a few cents a month for storage. Remove just the images, or the whole repository:

```bash
# Delete the latest tag's image only
aws ecr batch-delete-image --region "$AWS_REGION" --repository-name product-service --image-ids imageTag=latest

# Delete the repository and everything in it (force_delete = true lets Terraform remove it with images inside)
terraform -chdir=terraform destroy -target=aws_ecr_repository.app -target=aws_ecr_lifecycle_policy.app
```
`terraform destroy` shows what it will delete and asks you to type `yes`.

## Next

Once the image is in ECR, the full stack (VPC, RDS, ECS, ALB) can be deployed with a full `terraform apply`; see [runbook.md](runbook.md). The ECS tasks pull `product-service:latest` from this repository.
