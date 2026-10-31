# Remote state in S3 with native locking (use_lockfile, Terraform >= 1.10), so no DynamoDB table is needed.
# The bucket name contains the AWS account ID, so it is not hard-coded here. Supply it at init time
# (copy backend.hcl.example to backend.hcl, which is git-ignored):
#   terraform init -backend-config=backend.hcl
# Existing local state is copied with:  terraform init -backend-config=backend.hcl -migrate-state
# See "Remote state" in README.md.
terraform {
  backend "s3" {
    key          = "secure-containerized-microservices-app-aws/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
