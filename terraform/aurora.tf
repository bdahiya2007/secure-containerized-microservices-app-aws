# Aurora Global Database, Region A (enable_aurora). Off by default; written for the disaster recovery design in
# docs/DR_Design_Decisions.md and not yet applied.
#
# What it replaces: the RDS instance in rds.tf. Aurora Global Database does not support Secrets Manager managed credentials,
# so the password is generated here as a write-only value (never stored in Terraform state), kept in a self-managed secret,
# and rotated by the function in lambdas/db-rotation. The app is unchanged: it still reads the secret named in DB_SECRET_ARN.
# The secret can be replicated to the recovery Region (enable_dr_replica) for the Region B stack.

# ---- The password: a write-only value, in neither the state nor the plan ----
ephemeral "aws_secretsmanager_random_password" "db" {
  count = var.enable_aurora ? 1 : 0

  password_length = 32
  # RDS rejects / ' " @ and spaces; the backslash is left out as well because it is easy to mangle in a shell
  exclude_characters = "/@\"' \\"
}

# ---- A customer-managed key for the Region A cluster's storage and the database secret ----
# (The Region B cluster has its own key in terraform/region-b: a global database cannot share one key between Regions.)
# Written out instead of left to the default, with the same effect: the account's own IAM policies decide who may use the key.
# The task role, the migration task and the rotation function are given kms:Decrypt (and the rotation function also
# kms:GenerateDataKey) in their own policies, only through Secrets Manager. No other principal is named and nothing is public.
data "aws_iam_policy_document" "aurora_key" {
  #checkov:skip=CKV_AWS_356,CKV_AWS_109,CKV_AWS_111: this is a KMS key policy, where Resource "*" means only this key, and the account-root statement is the AWS default that hands access decisions to IAM; the IAM-policy rules do not fit a key policy
  count = var.enable_aurora ? 1 : 0

  statement {
    sid       = "EnableAccountAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "aurora" {
  count = var.enable_aurora ? 1 : 0

  description             = "Aurora primary cluster storage and the database secret (Region A)"
  enable_key_rotation     = true
  deletion_window_in_days = 7 # the shortest, so a demo rebuild is not blocked for long
  policy                  = data.aws_iam_policy_document.aurora_key[0].json
}

resource "aws_kms_alias" "aurora" {
  count = var.enable_aurora ? 1 : 0

  name          = "alias/${var.project_name}-aurora"
  target_key_id = aws_kms_key.aurora[0].key_id
}

# ---- The global cluster, its Region A primary cluster and its serverless instance ----
resource "aws_rds_global_cluster" "main" {
  count = var.enable_aurora ? 1 : 0

  global_cluster_identifier = "${var.project_name}-global"
  engine                    = "aurora-postgresql"
  engine_version            = var.aurora_engine_version
  database_name             = var.db_name
  storage_encrypted         = true

  # Demo: a destroy detaches any member cluster first (the Region B stack still has to be destroyed before this one)
  force_destroy       = true
  deletion_protection = false
}

# Log groups created first so they get a 14-day retention (RDS would otherwise create them with no expiry)
resource "aws_cloudwatch_log_group" "aurora_postgresql" {
  count             = var.enable_aurora && var.enable_rds_logs ? 1 : 0
  name              = "/aws/rds/cluster/${var.project_name}-aurora/postgresql"
  retention_in_days = 14
}

resource "aws_rds_cluster" "primary" {
  count = var.enable_aurora ? 1 : 0

  cluster_identifier        = "${var.project_name}-aurora"
  engine                    = aws_rds_global_cluster.main[0].engine
  engine_version            = aws_rds_global_cluster.main[0].engine_version
  global_cluster_identifier = aws_rds_global_cluster.main[0].id
  database_name             = var.db_name
  storage_encrypted         = true
  kms_key_id                = aws_kms_key.aurora[0].arn

  master_username = var.db_username
  # Write-only: sent to RDS and then forgotten. The rotation function changes the real password later, and the same
  # value goes into the secret below. Bump db_password_version to set a fresh one.
  master_password_wo         = ephemeral.aws_secretsmanager_random_password.db[0].random_password
  master_password_wo_version = var.db_password_version

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]

  serverlessv2_scaling_configuration {
    min_capacity = var.aurora_min_capacity
    max_capacity = var.aurora_max_capacity
  }

  backup_retention_period         = 7
  copy_tags_to_snapshot           = true
  deletion_protection             = false # set true for production
  skip_final_snapshot             = true  # set false for production
  enabled_cloudwatch_logs_exports = var.enable_rds_logs ? ["postgresql"] : []

  depends_on = [aws_cloudwatch_log_group.aurora_postgresql]

  # Minor upgrades are applied through the global cluster; without this the next plan would try to move the version back
  lifecycle {
    ignore_changes = [engine_version]
  }
}

resource "aws_rds_cluster_instance" "primary" {
  count = var.enable_aurora ? 1 : 0

  identifier           = "${var.project_name}-aurora-1"
  cluster_identifier   = aws_rds_cluster.primary[0].id
  engine               = aws_rds_cluster.primary[0].engine
  engine_version       = aws_rds_cluster.primary[0].engine_version
  instance_class       = "db.serverless"
  db_subnet_group_name = aws_db_subnet_group.main.name
  publicly_accessible  = false

  # The default, stated: minor upgrades are applied through the global cluster, and AWS documents that this setting has no
  # effect on a cluster that is part of a global database
  auto_minor_version_upgrade = true

  lifecycle {
    ignore_changes = [engine_version]
  }
}

# ---- The self-managed secret the app reads (DB_SECRET_ARN) ----
resource "aws_secretsmanager_secret" "db" {
  count = var.enable_aurora ? 1 : 0

  name        = "${var.project_name}/aurora-master"
  description = "Aurora master credentials for ${var.project_name}. Self-managed: rotated by ${var.project_name}-db-rotation."
  kms_key_id  = aws_kms_key.aurora[0].arn

  # Demo: delete at once on destroy, so a rebuilt stack can reuse the name (the default keeps it for 30 days)
  recovery_window_in_days = 0

  # Copies of every version in the recovery Region, for the Region B stack. The copy is encrypted with that Region's
  # AWS-managed Secrets Manager key: a customer-managed key there would have to exist before this stack is applied,
  # and it is created later by the Region B stack.
  dynamic "replica" {
    for_each = var.enable_dr_replica ? [var.dr_region] : []
    content {
      region = replica.value
    }
  }
}

resource "aws_secretsmanager_secret_version" "db" {
  count = var.enable_aurora ? 1 : 0

  secret_id = aws_secretsmanager_secret.db[0].id
  # Write-only, like the cluster's password. The fields match what the app and the rotation function read.
  secret_string_wo = jsonencode({
    engine              = "postgres"
    host                = aws_rds_cluster.primary[0].endpoint
    port                = aws_rds_cluster.primary[0].port
    username            = var.db_username
    password            = ephemeral.aws_secretsmanager_random_password.db[0].random_password
    dbname              = var.db_name
    dbClusterIdentifier = aws_rds_cluster.primary[0].cluster_identifier
  })
  secret_string_wo_version = var.db_password_version

  # Rotation moves the AWSCURRENT label to a newer version. Without this, the next plan would see the label gone from this
  # version and move it back, undoing the rotation.
  lifecycle {
    ignore_changes = [version_stages]
  }
}

# ---- The rotation function (lambdas/db-rotation), without a VPC: it only calls the Secrets Manager and RDS APIs ----
data "archive_file" "db_rotation" {
  count = var.enable_aurora ? 1 : 0

  type        = "zip"
  source_file = "${path.module}/../lambdas/db-rotation/lambda_function.py"
  output_path = "${path.module}/db-rotation.zip"
}

resource "aws_cloudwatch_log_group" "db_rotation" {
  count             = var.enable_aurora ? 1 : 0
  name              = "/aws/lambda/${var.project_name}-db-rotation"
  retention_in_days = 14
}

resource "aws_iam_role" "db_rotation" {
  count = var.enable_aurora ? 1 : 0

  name = "${var.project_name}-db-rotation"

  # Only Lambda, only in this account (the same confused-deputy condition as the ECS roles)
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "db_rotation" {
  count = var.enable_aurora ? 1 : 0

  name = "rotate-the-aurora-master-password"
  role = aws_iam_role.db_rotation[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "OneSecret"
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue",
          "secretsmanager:UpdateSecretVersionStage",
        ]
        Resource = aws_secretsmanager_secret.db[0].arn
      },
      {
        # The function only generates a random value here; the action takes no resource
        Sid      = "GenerateAPassword"
        Effect   = "Allow"
        Action   = "secretsmanager:GetRandomPassword"
        Resource = "*"
      },
      {
        # Only through Secrets Manager, and only this key: the secret is encrypted with it
        Sid      = "UseTheSecretKey"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.aurora[0].arn
        Condition = {
          StringEquals = { "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com" }
        }
      },
      {
        Sid      = "OneCluster"
        Effect   = "Allow"
        Action   = ["rds:ModifyDBCluster", "rds:DescribeDBClusters"]
        Resource = aws_rds_cluster.primary[0].arn
      },
      {
        Sid      = "OwnLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.db_rotation[0].arn}:*"
      },
      {
        # Active tracing sends trace segments; these actions take no resource
        Sid      = "Tracing"
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_lambda_function" "db_rotation" {
  count = var.enable_aurora ? 1 : 0

  function_name = "${var.project_name}-db-rotation"
  role          = aws_iam_role.db_rotation[0].arn
  runtime       = "python3.13"
  handler       = "lambda_function.lambda_handler"
  timeout       = 60
  memory_size   = 128

  filename         = data.archive_file.db_rotation[0].output_path
  source_code_hash = data.archive_file.db_rotation[0].output_base64sha256

  tracing_config {
    mode = "Active"
  }

  depends_on = [aws_cloudwatch_log_group.db_rotation, aws_iam_role_policy.db_rotation]
}

# Only Secrets Manager, only from this account, may call the function
resource "aws_lambda_permission" "db_rotation" {
  count = var.enable_aurora ? 1 : 0

  statement_id   = "AllowSecretsManagerToRotate"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.db_rotation[0].function_name
  principal      = "secretsmanager.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
}

resource "aws_secretsmanager_secret_rotation" "db" {
  count = var.enable_aurora ? 1 : 0

  secret_id           = aws_secretsmanager_secret.db[0].id
  rotation_lambda_arn = aws_lambda_function.db_rotation[0].arn

  # No rotation at apply time: the database may still be starting. The drill triggers one on purpose, and the schedule
  # does the rest.
  rotate_immediately = false

  rotation_rules {
    automatically_after_days = var.db_rotation_days
  }

  depends_on = [aws_lambda_permission.db_rotation, aws_secretsmanager_secret_version.db, aws_rds_cluster_instance.primary]
}
