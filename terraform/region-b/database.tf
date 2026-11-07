# The Aurora secondary cluster of the global database: a read-only copy of Region A's data, kept in step by Aurora's storage
# layer (docs/Disaster_Recovery_Exploration.md). It takes writes only after a failover promotes it. No master user or password
# here: a secondary cluster inherits them from the primary, and the secret is replicated by the main stack (enable_dr_replica).

# Encrypted storage needs a key in this Region; a global database cannot reuse Region A's key
resource "aws_kms_key" "db" {
  description             = "Aurora secondary cluster storage (Region B)"
  enable_key_rotation     = true
  deletion_window_in_days = 7 # the shortest, so a demo rebuild is not blocked for long
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

  lifecycle {
    ignore_changes = [engine_version]
  }
}
