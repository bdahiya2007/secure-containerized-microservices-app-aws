# CodeDeploy blue/green for the ECS service, started by the GitHub Actions deploy workflow
# (.github/workflows/deploy.yml). Everything here exists only when enable_blue_green is true.
#
# How a deployment works: the workflow registers a new task definition revision and calls
# CodeDeploy with appspec.yaml. CodeDeploy starts the new tasks in the idle (green) target group,
# waits for them to pass the ALB health check, shifts the listener's traffic gradually, then stops
# the old (blue) tasks after a wait. If the new tasks never become healthy, traffic never moves.

locals {
  blue_green = var.enable_blue_green ? 1 : 0
}

# The second target group. CodeDeploy alternates between this and aws_lb_target_group.app.
resource "aws_lb_target_group" "green" {
  count = local.blue_green

  name        = "${var.project_name}-tg-green"
  port        = 3000
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  deregistration_delay = 30

  health_check {
    path    = "/health"
    matcher = "200"
  }
}

# Changes whenever the launch type or the capacity provider strategy changes. A CodeDeploy-controlled service cannot
# change either in place, so the service below is replaced when this does (replace_triggered_by).
resource "terraform_data" "capacity_strategy" {
  input = var.enable_fargate_spot ? jsonencode(local.capacity_provider_strategy) : "launch-type-FARGATE"
}

# The same service as aws_ecs_service.app, but CodeDeploy controls its deployments.
# The circuit breaker is not available with this controller; CodeDeploy's own rollback replaces it.
resource "aws_ecs_service" "blue_green" {
  count = local.blue_green

  name            = var.project_name
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = var.desired_count

  # A service uses either a launch type or a capacity provider strategy, never both
  launch_type = var.enable_fargate_spot ? null : "FARGATE"

  # The provider requires this when a strategy changes. Strategy changes replace this service (see
  # terraform_data.capacity_strategy), so no in-place update is ever sent.
  force_new_deployment = var.enable_fargate_spot

  # With a strategy, the same strategy must go into the appspec so that the tasks CodeDeploy starts follow it; the
  # deploy workflow copies it from this service (see .github/workflows/deploy.yml).
  dynamic "capacity_provider_strategy" {
    for_each = var.enable_fargate_spot ? local.capacity_provider_strategy : []

    content {
      capacity_provider = capacity_provider_strategy.value.name
      base              = capacity_provider_strategy.value.base
      weight            = capacity_provider_strategy.value.weight
    }
  }

  health_check_grace_period_seconds = 60

  deployment_controller {
    type = "CODE_DEPLOY"
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

  # Each of these is changed by something other than Terraform:
  #  - desired_count: Auto Scaling (autoscaling.tf)
  #  - task_definition: every CodeDeploy deployment registers and switches to a new revision
  #  - load_balancer: CodeDeploy swaps the target group
  lifecycle {
    ignore_changes       = [desired_count, task_definition, load_balancer]
    replace_triggered_by = [terraform_data.capacity_strategy]
  }
}

# --- CodeDeploy service role ---------------------------------------------------------------

data "aws_iam_policy_document" "codedeploy_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }

    # Confused-deputy protection: only CodeDeploy acting for this account can use the role
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "codedeploy" {
  count = local.blue_green

  name               = "${var.project_name}-codedeploy"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_trust.json
}

# AWS's managed policy for ECS blue/green: ECS service updates, ALB listener and target group
# changes, and PassRole restricted to ecs-tasks.amazonaws.com
resource "aws_iam_role_policy_attachment" "codedeploy" {
  count = local.blue_green

  role       = aws_iam_role.codedeploy[0].name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}

# --- Application and deployment group ------------------------------------------------------

resource "aws_codedeploy_app" "app" {
  count = local.blue_green

  name             = var.project_name
  compute_platform = "ECS"
}

resource "aws_codedeploy_deployment_group" "app" {
  count = local.blue_green

  app_name               = aws_codedeploy_app.app[0].name
  deployment_group_name  = "${var.project_name}-dg"
  service_role_arn       = aws_iam_role.codedeploy[0].arn
  deployment_config_name = var.codedeploy_deployment_config

  ecs_service {
    cluster_name = aws_ecs_cluster.main.name
    service_name = aws_ecs_service.blue_green[0].name
  }

  deployment_style {
    deployment_type   = "BLUE_GREEN"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }

    # Keep the old tasks for a while after the switch so a rollback is instant
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = var.codedeploy_blue_termination_minutes
    }
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.http.arn]
      }

      target_group {
        name = aws_lb_target_group.app.name
      }

      target_group {
        name = aws_lb_target_group.green[0].name
      }
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_REQUEST"]
  }
}
