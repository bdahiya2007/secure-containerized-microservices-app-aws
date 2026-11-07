# The Region B app: one Fargate task behind the load balancer, the same image and settings as Region A. It reads the database
# secret's REPLICA in this Region (found by name: the replica has the same name as the original) and connects to the Aurora
# secondary's reader endpoint. The product service only reads, so it works before a failover promotes the cluster.

data "aws_secretsmanager_secret" "db" {
  name = data.terraform_remote_state.main.outputs.db_secret_name
}

resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${local.name}"
  retention_in_days = 14
}

resource "aws_ecs_cluster" "main" {
  name = "${local.name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# Trust policy for both ECS roles: only ECS acting for tasks in this account and Region can assume them (confused-deputy protection)
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# The task role's one permission: read the one (replicated) database secret. The execution role has no access to it.
resource "aws_iam_role_policy" "task_read_db_secret" {
  name = "read-db-secret"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = data.aws_secretsmanager_secret.db.arn
    }]
  })
}

resource "aws_ecs_task_definition" "app" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512

  # Must match the architecture the image was built for (docker build --platform linux/amd64)
  runtime_platform {
    cpu_architecture        = "X86_64"
    operating_system_family = "LINUX"
  }

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name                   = var.project_name
    image                  = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
    essential              = true
    readonlyRootFilesystem = true
    portMappings           = [{ containerPort = 3000, protocol = "tcp" }]

    environment = [
      { name = "DB_HOST", value = aws_rds_cluster.secondary.reader_endpoint },
      { name = "DB_PORT", value = tostring(aws_rds_cluster.secondary.port) },
      { name = "DB_NAME", value = var.db_name },
      { name = "DB_SSL", value = "true" },
      # The name (ARN) of the secret, not its value. The app fetches the username and password with the task role.
      { name = "DB_SECRET_ARN", value = data.aws_secretsmanager_secret.db.arn },
      { name = "AWS_REGION", value = var.aws_region },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.app.name
        awslogs-region        = var.aws_region
        awslogs-stream-prefix = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "app" {
  name            = local.name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Give the task time to start before the load balancer's health checks count against it
  health_check_grace_period_seconds = 60

  # Roll back automatically if a deployment's tasks can't become healthy
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.app.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = var.project_name
    container_port   = 3000
  }

  depends_on = [aws_lb_listener.https, aws_lb_listener.http, aws_rds_cluster_instance.secondary]

  # A failover scales this up by hand (aws ecs update-service); Terraform must not reset it
  lifecycle {
    ignore_changes = [desired_count]
  }
}
