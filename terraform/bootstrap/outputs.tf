output "deploy_role_arn" {
  description = "Set as the AWS_DEPLOY_ROLE_ARN repository secret"
  value       = aws_iam_role.deploy.arn
}
