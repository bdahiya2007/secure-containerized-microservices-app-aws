data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = var.aws_region

  # The account's existing GitHub OIDC provider (one per account). It is referenced, not created.
  oidc_provider_arn = "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"

  # Named inside the project_name-* pattern that docs/iam/product-service-iam-policy.json allows
  deploy_role_name = "${var.project_name}-deploy-role"
  deploy_role_arn  = "arn:aws:iam::${local.account_id}:role/${local.deploy_role_name}"

  ecr_repository_arn = "arn:aws:ecr:${local.region}:${local.account_id}:repository/${var.project_name}"
  # The two roles the task definition names (terraform/ecs.tf)
  task_role_arns = [
    "arn:aws:iam::${local.account_id}:role/${var.project_name}-execution",
    "arn:aws:iam::${local.account_id}:role/${var.project_name}-task",
  ]
  codedeploy_app_arn = "arn:aws:codedeploy:${local.region}:${local.account_id}:application:${var.project_name}"
  codedeploy_dg_arn  = "arn:aws:codedeploy:${local.region}:${local.account_id}:deploymentgroup:${var.project_name}/${var.project_name}-dg"
}

# ---------------------------------------------------------------------------
# GitHub Actions deploy role (assumed through the existing OIDC provider)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    sid     = "GitHubOidc"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # The deploy job always runs in a GitHub environment, whose sub claim ends in :environment:<name>.
    # Pull requests, other branches and other repositories cannot match.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [for e in var.github_environments : "${var.github_sub_prefix}:environment:${e}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = local.deploy_role_name
  description          = "Assumed by GitHub Actions to build, push and deploy the Product Service (no Terraform access)"
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "deploy" {
  # docker login. This action does not support resource-level permissions.
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Push one image to the existing repository and read its scan result
  statement {
    sid = "EcrPushToProductRepository"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:DescribeImages",
      "ecr:DescribeImageScanFindings",
    ]
    resources = [local.ecr_repository_arn]
  }

  # Neither action supports resource-level permissions. Registering only creates a new, inactive revision;
  # nothing runs until CodeDeploy deploys it.
  statement {
    sid       = "TaskDefinitions"
    actions   = ["ecs:DescribeTaskDefinition", "ecs:RegisterTaskDefinition"]
    resources = ["*"]
  }

  # A task definition may only name the project's own two roles, and only for ECS tasks
  statement {
    sid       = "PassOnlyTheTaskRoles"
    actions   = ["iam:PassRole"]
    resources = local.task_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # Start and follow deployments of this one application and deployment group
  statement {
    sid = "StartAndWatchDeployments"
    actions = [
      "codedeploy:GetDeploymentGroup",
      "codedeploy:CreateDeployment",
      "codedeploy:GetDeployment",
    ]
    resources = [local.codedeploy_dg_arn]
  }

  statement {
    sid = "DeploymentRevisions"
    actions = [
      "codedeploy:GetApplicationRevision",
      "codedeploy:RegisterApplicationRevision",
    ]
    resources = [local.codedeploy_app_arn]
  }

  statement {
    sid       = "DeploymentConfigurations"
    actions   = ["codedeploy:GetDeploymentConfig"]
    resources = ["arn:aws:codedeploy:${local.region}:${local.account_id}:deploymentconfig:*"]
  }

  # The identity call that masks the account ID in the logs needs no permission, but be explicit that the
  # role can never change itself. An explicit deny wins over every allow above.
  statement {
    sid       = "DenyPipelineSelfModification"
    effect    = "Deny"
    actions   = ["iam:*"]
    resources = [local.deploy_role_arn]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "DeployProductService"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
