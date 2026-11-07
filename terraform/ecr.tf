resource "aws_ecr_repository" "app" {
  name                 = var.project_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# Copies every image pushed to this registry whose repository name starts with the project name to the recovery Region, where the
# Region B stack runs it (terraform/region-b). Only with enable_dr_replica.
#
# CAUTION: replication is configured once per registry (account and Region), so this resource REPLACES any replication
# configuration the account already has. Check first: aws ecr describe-registry. Images pushed before this exists are not copied.
resource "aws_ecr_replication_configuration" "dr" {
  count = var.enable_aurora && var.enable_dr_replica ? 1 : 0

  replication_configuration {
    rule {
      destination {
        region      = var.dr_region
        registry_id = data.aws_caller_identity.current.account_id
      }

      repository_filter {
        filter      = var.project_name
        filter_type = "PREFIX_MATCH"
      }
    }
  }
}
