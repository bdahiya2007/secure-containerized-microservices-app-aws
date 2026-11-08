# The database the app and the migration task connect to: the RDS instance, or the Aurora cluster with enable_aurora.
# one(...) is null for the resource that is not created, so each branch is safe whichever switch is set.
locals {
  db_host       = var.enable_aurora ? one(aws_rds_cluster.primary[*].endpoint) : one(aws_db_instance.main[*].address)
  db_port       = var.enable_aurora ? one(aws_rds_cluster.primary[*].port) : one(aws_db_instance.main[*].port)
  db_secret_arn = var.enable_aurora ? one(aws_secretsmanager_secret.db[*].arn) : one(aws_db_instance.main[*].master_user_secret[0].secret_arn)

  # The host the running app connects to. With Aurora and app_uses_reader_endpoint (the default) it is the cluster's READER endpoint,
  # like Region B's app: the service only reads, and a reader endpoint keeps working when this cluster is a secondary after a
  # switchover or failover, where the writer endpoint stops serving. With one instance the reader endpoint reaches the writer
  # instance, so nothing changes in normal operation. The migration task keeps db_host: it writes.
  app_db_host = var.enable_aurora && var.app_uses_reader_endpoint ? one(aws_rds_cluster.primary[*].reader_endpoint) : local.db_host
}

# The instance gained a count; this keeps the existing one in state under its new address
moved {
  from = aws_db_instance.main
  to   = aws_db_instance.main[0]
}

# Log groups for the RDS log exports, created first so they get a 14-day retention
resource "aws_cloudwatch_log_group" "rds_postgresql" {
  count             = var.enable_rds_logs && !var.enable_aurora ? 1 : 0
  name              = "/aws/rds/instance/${var.project_name}-db/postgresql"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "rds_upgrade" {
  count             = var.enable_rds_logs && !var.enable_aurora ? 1 : 0
  name              = "/aws/rds/instance/${var.project_name}-db/upgrade"
  retention_in_days = 14
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db"
  subnet_ids = aws_subnet.private[*].id
}

# The RDS instance. With enable_aurora it is replaced by the Aurora cluster in aurora.tf.
resource "aws_db_instance" "main" {
  count = var.enable_aurora ? 0 : 1

  identifier     = "${var.project_name}-db"
  engine         = "postgres"
  engine_version = "18.6" # latest major on RDS (no extended support charges), pinned to a minor for repeatable builds
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  # RDS generates the master password and stores it in Secrets Manager (no secret in state or code)
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false

  copy_tags_to_snapshot      = true
  backup_retention_period    = 7
  deletion_protection        = false # set true for production
  skip_final_snapshot        = true  # set false for production
  auto_minor_version_upgrade = true

  # PostgreSQL and upgrade logs go to CloudWatch Logs when enable_rds_logs is on (RDS can't export to S3 directly)
  enabled_cloudwatch_logs_exports = var.enable_rds_logs ? ["postgresql", "upgrade"] : []

  # RDS would otherwise create these log groups itself, with no expiry
  depends_on = [aws_cloudwatch_log_group.rds_postgresql, aws_cloudwatch_log_group.rds_upgrade]

  # RDS applies minor upgrades itself; without this, the next plan would try to downgrade to the pinned minor
  lifecycle {
    ignore_changes = [engine_version]
  }
}
