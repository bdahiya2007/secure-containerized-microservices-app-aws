output "alb_dns_name" {
  value = aws_lb.app.dns_name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "rds_endpoint" {
  description = "The database endpoint the app uses (the RDS instance, or the Aurora cluster with enable_aurora)"
  value       = local.db_host
}

output "db_secret_arn" {
  value = local.db_secret_arn
}

output "log_bucket" {
  description = "Central S3 log bucket (prefixes: alb/, cloudtrail/)"
  value       = aws_s3_bucket.logs.id
}

output "s3_access_log_bucket" {
  description = "Separate bucket for S3 server access logs of the central bucket (empty when enable_s3_access_logging is off)"
  value       = one(aws_s3_bucket.s3_access_logs[*].id)
}

output "dashboard_url" {
  description = "CloudWatch dashboard for the service"
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${aws_cloudwatch_dashboard.main.dashboard_name}"
}

# Used to run the one-off schema migration task: aws ecs run-task (see docs/runbook.md)
output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "migrate_task_definition" {
  value = aws_ecs_task_definition.migrate.family
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "app_security_group_id" {
  value = aws_security_group.app.id
}

output "codedeploy_app_name" {
  description = "CodeDeploy application (empty unless enable_blue_green)"
  value       = one(aws_codedeploy_app.app[*].name)
}

output "codedeploy_deployment_group_name" {
  description = "CodeDeploy deployment group (empty unless enable_blue_green)"
  value       = one(aws_codedeploy_deployment_group.app[*].deployment_group_name)
}

output "app_url" {
  description = "Where the app is served: https://app_domain with enable_https, otherwise the load balancer's own HTTP address"
  value       = var.enable_https ? "https://${var.app_domain}" : "http://${aws_lb.app.dns_name}"
}

output "global_cluster_id" {
  description = "The Aurora global cluster (empty unless enable_aurora); the Region B stack attaches its secondary cluster to it"
  value       = one(aws_rds_global_cluster.main[*].id)
}

output "aurora_cluster_arn" {
  description = "The Region A Aurora cluster (empty unless enable_aurora)"
  value       = one(aws_rds_cluster.primary[*].arn)
}

output "db_rotation_function" {
  description = "The Secrets Manager rotation function for the Aurora master password (empty unless enable_aurora)"
  value       = one(aws_lambda_function.db_rotation[*].function_name)
}

output "global_cluster_engine_version" {
  description = "The global cluster's engine version (empty unless enable_aurora); the Region B secondary must run the same major and minor version"
  value       = one(aws_rds_global_cluster.main[*].engine_version)
}

output "db_secret_name" {
  description = "The database secret's name (empty unless enable_aurora); the Region B stack finds its replica by this name"
  value       = one(aws_secretsmanager_secret.db[*].name)
}

output "failover_health_check_id" {
  description = "The Route 53 health check behind the PRIMARY record (empty unless enable_dr_failover)"
  value       = one(aws_route53_health_check.primary[*].id)
}

output "failover_alarm_name" {
  description = "The CloudWatch alarm the health check follows (empty unless enable_dr_failover). Setting it to ALARM by hand rehearses a failover without touching the app."
  value       = one(aws_cloudwatch_metric_alarm.no_running_tasks[*].alarm_name)
}
