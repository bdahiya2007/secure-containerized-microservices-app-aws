output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "app_security_group_id" {
  value = aws_security_group.app.id
}

output "db_security_group_id" {
  value = aws_security_group.db.id
}

output "aurora_cluster_arn" {
  description = "The Region B Aurora secondary cluster"
  value       = aws_rds_cluster.secondary.arn
}

output "aurora_cluster_identifier" {
  description = "The identifier the failover command promotes: aws rds failover-global-cluster --target-db-cluster-identifier <this cluster's ARN>"
  value       = aws_rds_cluster.secondary.cluster_identifier
}

output "db_reader_endpoint" {
  description = "Where the Region B app connects. The product service only reads, so the reader endpoint works before and after a promotion (with one instance it reaches the writer)."
  value       = aws_rds_cluster.secondary.reader_endpoint
}

output "app_url" {
  description = "Region B's own HTTPS name, for testing it directly before a failover"
  value       = "https://${var.app_domain}"
}

output "alb_dns_name" {
  value = aws_lb.app.dns_name
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "ecs_service_name" {
  value = aws_ecs_service.app.name
}

output "ecr_repository_url" {
  description = "Where the main stack's replication rule copies images to"
  value       = aws_ecr_repository.app.repository_url
}
