variable "aws_region" {
  description = "Region the application is deployed in"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name of the application stack (the deploy role, ECR repository, ECS roles and CodeDeploy names derive from it). Must match terraform/variables.tf."
  type        = string
  default     = "product-service"
}

variable "github_sub_prefix" {
  description = <<-EOT
    The repository's OIDC subject prefix, exactly as GitHub reports it, for example
    repo:<owner>@<owner-id>/<repo>@<repo-id>. Get it with:
      gh api repos/<owner>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix
    (after enabling immutable subjects, see docs/CICD.md). It pins the trust to this exact repository.
  EOT
  type        = string

  validation {
    condition     = can(regex("^repo:[^:]+@[0-9]+/[^:]+@[0-9]+$", var.github_sub_prefix))
    error_message = "github_sub_prefix must look like repo:<owner>@<id>/<repo>@<id> (immutable IDs, no branch or environment)."
  }
}

variable "github_environments" {
  description = "GitHub environments whose jobs may assume the deploy role"
  type        = list(string)
  default     = ["dev"]
}
