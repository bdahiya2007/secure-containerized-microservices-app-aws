resource "aws_cloudwatch_log_group" "app" {
  name              = "/ecs/${var.project_name}"
  retention_in_days = 14
}

resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}

# Fargate and Fargate Spot as capacity providers. Registering both is free and changes nothing by itself: services
# keep running on the launch type or strategy they name. The cluster default is on-demand Fargate only, so
# anything that names no strategy never lands on Spot by accident.
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1
    weight            = 1
  }
}

locals {
  # The service's capacity provider strategy when enable_fargate_spot is on. ECS places the first fargate_base tasks on
  # on-demand Fargate (they survive a Spot interruption), then splits the rest by weight. With the defaults (base 1,
  # weights 1 and 3) a service of 2 tasks runs 1 on-demand and 1 Spot; at 4 tasks, 2 and 2 or 1 and 3.
  capacity_provider_strategy = [
    { name = "FARGATE", base = var.fargate_base, weight = var.fargate_weight },
    { name = "FARGATE_SPOT", base = 0, weight = var.fargate_spot_weight },
  ]
}

# ---- IAM ----
data "aws_caller_identity" "current" {}

# Trust policy for both ECS roles. The two conditions are AWS's confused-deputy protection: only ECS
# acting for tasks in this account can assume the roles.
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
  name               = "${var.project_name}-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The execution role has no access to the database secret: the app reads it itself with the task role (below), and ECS no
# longer injects it into the container (docs/Secrets.md).

resource "aws_iam_role" "task" {
  name               = "${var.project_name}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

# The app reads the database credentials from Secrets Manager itself, at runtime (product-service/src/db-secret.js),
# so the task role holds the one permission needed to do that, on the one secret RDS manages for this database.
resource "aws_iam_role_policy" "task_read_db_secret" {
  name = "read-db-secret"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_db_instance.main.master_user_secret[0].secret_arn
    }]
  })
}

# ---- Task definition & service ----
resource "aws_ecs_task_definition" "app" {
  family                   = var.project_name
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
      { name = "DB_HOST", value = aws_db_instance.main.address },
      { name = "DB_PORT", value = tostring(aws_db_instance.main.port) },
      { name = "DB_NAME", value = var.db_name },
      { name = "DB_SSL", value = "true" },
      # The name (ARN) of the secret, not its value. The app fetches the username and password with the task role.
      { name = "DB_SECRET_ARN", value = aws_db_instance.main.master_user_secret[0].secret_arn },
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
  # Exactly one of this service and aws_ecs_service.blue_green (codedeploy.tf) exists: switching
  # enable_blue_green changes the deployment controller, which ECS cannot do in place.
  count = var.enable_blue_green ? 0 : 1

  name            = var.project_name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count

  # A service uses either a launch type or a capacity provider strategy, never both
  launch_type = var.enable_fargate_spot ? null : "FARGATE"

  # Moving between a launch type and a strategy needs a new deployment (and replaces the service)
  force_new_deployment = var.enable_fargate_spot

  dynamic "capacity_provider_strategy" {
    for_each = var.enable_fargate_spot ? local.capacity_provider_strategy : []

    content {
      capacity_provider = capacity_provider_strategy.value.name
      base              = capacity_provider_strategy.value.base
      weight            = capacity_provider_strategy.value.weight
    }
  }

  # Give new tasks time to start before the load balancer's health checks count against them
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

  depends_on = [aws_lb_listener.http, aws_ecs_cluster_capacity_providers.main]

  # Auto Scaling (autoscaling.tf) changes the desired count, so Terraform must not reset it
  lifecycle {
    ignore_changes = [desired_count]
  }
}

# The service was a single resource before enable_blue_green existed
moved {
  from = aws_ecs_service.app
  to   = aws_ecs_service.app[0]
}

locals {
  # Whichever service exists; autoscaling.tf and monitoring.tf use this name
  service_name = coalesce(
    one(aws_ecs_service.app[*].name),
    one(aws_ecs_service.blue_green[*].name),
  )
}

# ---- Load balancer ----
resource "aws_lb" "app" {
  name               = "${var.project_name}-alb"
  load_balancer_type = "application"
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]

  drop_invalid_header_fields = true

  access_logs {
    bucket  = aws_s3_bucket.logs.id
    prefix  = "alb"
    enabled = true
  }

  # The load balancer checks that it can write to the bucket when this is applied
  depends_on = [aws_s3_bucket_policy.logs]
}

resource "aws_lb_target_group" "app" {
  name        = "${var.project_name}-tg"
  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  # The app stops in about 3 seconds, so don't hold connections open for the 5-minute default
  deregistration_delay = 30

  health_check {
    path    = "/health"
    matcher = "200"
  }
}

# HTTP only for the demo; add an ACM cert and HTTPS listener for production.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  # With enable_blue_green, CodeDeploy moves this action between the blue and green target groups on
  # every deployment, so Terraform must not move it back. Its only job here is the initial value.
  lifecycle {
    ignore_changes = [default_action]
  }
}
