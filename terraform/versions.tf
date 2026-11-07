terraform {
  required_version = ">= 1.11" # use_lockfile in backend.tf needs 1.10; the Aurora write-only password arguments need 1.11

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.71"
    }
    # Zips the rotation function (lambdas/db-rotation) for the Aurora secret (enable_aurora)
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "terraform"
    }
  }
}
