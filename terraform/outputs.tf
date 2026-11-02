output "alb_dns_name" {
  value = aws_lb.app.dns_name
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "rds_endpoint" {
  value = aws_db_instance.main.address
}

output "db_secret_arn" {
  value = aws_db_instance.main.master_user_secret[0].secret_arn
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
