# Region B has its own state, separate from the main stack, so a Region B problem can never block a Region A plan and the two
# are destroyed independently (Region B first). Same bucket and settings as the main stack, with its own key. Supply the bucket
# name (it contains the account ID) at init time: copy backend.hcl.example to backend.hcl (git-ignored) and run
#   terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {
    key          = "secure-containerized-microservices-app-aws/region-b.tfstate"
    region       = "us-east-1" # where the state bucket is; not the Region this stack builds in
    encrypt      = true
    use_lockfile = true
  }
}
