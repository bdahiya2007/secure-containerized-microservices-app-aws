# What the main stack publishes: the global cluster to attach to, its engine version, and the secret's name. The main stack
# (with enable_aurora and enable_dr_replica) must be applied first, so these outputs exist.
data "terraform_remote_state" "main" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = var.main_state_key
    region = var.primary_region
  }
}

locals {
  global_cluster_id = data.terraform_remote_state.main.outputs.global_cluster_id
  engine_version    = data.terraform_remote_state.main.outputs.global_cluster_engine_version
}
