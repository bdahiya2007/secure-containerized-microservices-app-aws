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
  # on-demand Fargate (they survive a Spot interruption), then splits the rest by weight. With the defaults (base 2,
  # weights 1 and 3) a service of 2 tasks runs 2 on-demand tasks, which ECS spreads over two Availability Zones; the
  # third and fourth tasks of a scale-out are mostly Spot.
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
      Resource = local.db_secret_arn
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
    name = var.project_name
    # A service that Terraform creates or recreates starts from this tag. The deploy workflow moves :latest to every image that
    # deployed successfully, so it always exists (see docs/CICD.md).
    image                  = "${aws_ecr_repository.app.repository_url}:${var.image_tag}"
    essential              = true
    readonlyRootFilesystem = true
    portMappings           = [{ containerPort = 3000, protocol = "tcp" }]

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

  depends_on = [aws_lb_listener.http, aws_lb_listener.https, aws_ecs_cluster_capacity_providers.main]

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

# Port 80. Without enable_https this is the only listener and the one CodeDeploy shifts traffic on.
resource "aws_lb_listener" "http" {
  # With blue/green, CodeDeploy points this listener at the green target group too, which Terraform cannot see. Without this
  # dependency a destroy can try to delete the green group while the listener still uses it (ResourceInUse, found when the
  # stack was destroyed). With it, the listener is deleted first. It changes nothing on create.
  depends_on = [aws_lb_target_group.green]

  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  # With enable_blue_green, CodeDeploy moves this action between the blue and green target groups on
  # every deployment, so Terraform must not move it back. Its only job here is the initial value.
  # A CodeDeploy deployment leaves this on whichever target group it last used, but a service that Terraform creates
  # always registers its tasks in the blue group (aws_lb_target_group.app). Without this, replacing the service (switching
  # Fargate Spot or its base on, say) can leave the listener on the empty green group and every request returns 503
  # (found in the Fargate Spot test: about 8 extra minutes of outage). So when the service is replaced, the listener is
  # replaced with it, and a new listener starts on blue. Only needed when enable_blue_green is on; the marker changes
  # exactly when the blue/green service is replaced.
  lifecycle {
    ignore_changes       = [default_action]
    replace_triggered_by = [terraform_data.capacity_strategy]
  }
}

# HTTPS (enable_https). This listener becomes the one CodeDeploy shifts traffic on (see codedeploy.tf), so it has the same
# lifecycle rules as the HTTP listener above. Port 80 then only redirects.
resource "aws_lb_listener" "https" {
  # With blue/green, CodeDeploy points this listener at the green target group too, which Terraform cannot see. Without this
  # dependency a destroy can try to delete the green group while the listener still uses it (ResourceInUse, found when the
  # stack was destroyed). With it, the listener is deleted first. It changes nothing on create.
  depends_on = [aws_lb_target_group.green]

  count = var.enable_https ? 1 : 0

  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.app[0].certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  lifecycle {
    ignore_changes       = [default_action]
    replace_triggered_by = [terraform_data.capacity_strategy]
  }
}

# A rule is evaluated before the listener's default action, so every request on port 80 is redirected to HTTPS
# whichever target group the HTTP listener's default action points at after a deployment.
resource "aws_lb_listener_rule" "http_redirect" {
  count = var.enable_https ? 1 : 0

  listener_arn = aws_lb_listener.http.arn
  priority     = 1

  action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }
}
