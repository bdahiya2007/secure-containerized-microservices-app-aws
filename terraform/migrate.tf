# One-off task that loads product-service/db/schema.sql into the private RDS instance.
# There is no service: run it once after the apply with `aws ecs run-task` (see docs/runbook.md).
# It runs the application's own image (which contains db/schema.sql and src/migrate.js), so no
# third-party image is pulled. It reuses the cluster, the app security group (the only one the
# database accepts), the execution role (which can read the database secret) and the log group.
resource "aws_ecs_task_definition" "migrate" {
  family                   = "${var.project_name}-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512

  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name                   = "migrate"
    image                  = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
    essential              = true
    readonlyRootFilesystem = true
    command                = ["node", "src/migrate.js"]

    environment = [
      { name = "DB_HOST", value = local.db_host },
      { name = "DB_PORT", value = tostring(local.db_port) },
      { name = "DB_NAME", value = var.db_name },
      { name = "DB_SSL", value = "true" },
      # The name (ARN) of the secret, not its value. The app fetches the username and password with the task role.
      { name = "DB_SECRET_ARN", value = local.db_secret_arn },
      { name = "AWS_REGION", value = var.aws_region },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "migrate"
      }
    }
  }])
}
