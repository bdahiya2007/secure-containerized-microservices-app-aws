# The Aurora secondary cluster of the global database: a read-only copy of Region A's data, kept in step by Aurora's storage
# layer (docs/Disaster_Recovery_Exploration.md). It takes writes only after a failover promotes it. No master user or password
# here: a secondary cluster inherits them from the primary, and the secret is replicated by the main stack (enable_dr_replica).

data "aws_caller_identity" "current" {}

# Written out instead of left to the default, with the same effect: the account's own IAM policies decide who may use the key.
# No other principal is named and nothing is public.
data "aws_iam_policy_document" "db_key" {
  #checkov:skip=CKV_AWS_356,CKV_AWS_109,CKV_AWS_111: this is a KMS key policy, where Resource "*" means only this key, and the account-root statement is the AWS default that hands access decisions to IAM; the IAM-policy rules do not fit a key policy
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

# Encrypted storage needs a key in this Region; a global database cannot reuse Region A's key
resource "aws_kms_key" "db" {
  description             = "Aurora secondary cluster storage (Region B)"
  enable_key_rotation     = true
  deletion_window_in_days = 7 # the shortest, so a demo rebuild is not blocked for long
  policy                  = data.aws_iam_policy_document.db_key.json
}

resource "aws_kms_alias" "db" {
  name          = "alias/${local.name}-aurora"
  target_key_id = aws_kms_key.db.key_id
}

resource "aws_db_subnet_group" "main" {
  name       = "${local.name}-db"
  subnet_ids = aws_subnet.private[*].id
}

# Created first so the log group gets a 14-day retention (RDS would otherwise create it with no expiry)
resource "aws_cloudwatch_log_group" "aurora_postgresql" {
  count             = var.enable_rds_logs ? 1 : 0
  name              = "/aws/rds/cluster/${local.name}-aurora/postgresql"
  retention_in_days = 14
}

resource "aws_rds_cluster" "secondary" {
  cluster_identifier        = "${local.name}-aurora"
  engine                    = "aurora-postgresql"
  engine_version            = local.engine_version
  global_cluster_identifier = local.global_cluster_id

  storage_encrypted = true
  kms_key_id        = aws_kms_key.db.arn
  source_region     = var.primary_region

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]

  serverlessv2_scaling_configuration {
    min_capacity = var.aurora_min_capacity
    max_capacity = var.aurora_max_capacity
  }

  copy_tags_to_snapshot           = true
  deletion_protection             = false # set true for production
  skip_final_snapshot             = true  # set false for production
  enabled_cloudwatch_logs_exports = var.enable_rds_logs ? ["postgresql"] : []

  depends_on = [aws_cloudwatch_log_group.aurora_postgresql]

  lifecycle {
    # The replication source is managed by the global cluster; minor upgrades go through the global cluster too
    ignore_changes = [replication_source_identifier, engine_version]
  }
}

resource "aws_rds_cluster_instance" "secondary" {
  identifier           = "${local.name}-aurora-1"
  cluster_identifier   = aws_rds_cluster.secondary.id
  engine               = aws_rds_cluster.secondary.engine
  engine_version       = aws_rds_cluster.secondary.engine_version
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
