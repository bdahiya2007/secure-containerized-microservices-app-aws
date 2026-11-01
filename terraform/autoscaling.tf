# Application Auto Scaling for the ECS service. Target tracking creates and manages the CloudWatch
# alarms itself. ECS then changes the service's desired count between the minimum and maximum,
# which is why the service ignores later changes to desired_count (see ecs.tf).
resource "aws_appautoscaling_target" "ecs" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.main.name}/${local.service_name}"
  min_capacity       = var.autoscaling_min_capacity
  max_capacity       = var.autoscaling_max_capacity

  lifecycle {
    precondition {
      condition     = var.autoscaling_min_capacity >= 1 && var.autoscaling_min_capacity <= var.autoscaling_max_capacity
      error_message = "autoscaling_min_capacity must be at least 1 and no larger than autoscaling_max_capacity."
    }
  }
}

# Scale on average CPU across the tasks.
resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.project_name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  resource_id        = aws_appautoscaling_target.ecs.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling_cpu_target
    scale_out_cooldown = 60  # add tasks quickly when load rises
    scale_in_cooldown  = 300 # remove them slowly, so a brief dip doesn't shrink the service

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

# Scale on requests per task through the ALB. This reacts to traffic before CPU does.
resource "aws_appautoscaling_policy" "requests" {
  name               = "${var.project_name}-requests"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  resource_id        = aws_appautoscaling_target.ecs.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling_requests_per_target
    scale_out_cooldown = 60
    scale_in_cooldown  = 300

    # Rolling updates: one target group, so the built-in metric works.
    dynamic "predefined_metric_specification" {
      for_each = var.enable_blue_green ? [] : [1]

      content {
        predefined_metric_type = "ALBRequestCountPerTarget"
        resource_label         = "${aws_lb.app.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
      }
    }

    # Blue/green: CodeDeploy alternates traffic between two target groups, and the built-in metric watches only one
    # of them (it reads zero while the other is live, so the policy would stop scaling). Add the requests of both
    # groups and divide by the running tasks, which is what ALBRequestCountPerTarget measures. The idle group has
    # no data, so FILL turns the gap into 0. Running tasks come from Container Insights (enabled on the cluster).
    dynamic "customized_metric_specification" {
      for_each = var.enable_blue_green ? [1] : []

      content {
        metrics {
          id    = "requests_blue"
          label = "Requests, blue target group"

          metric_stat {
            stat = "Sum"

            metric {
              namespace   = "AWS/ApplicationELB"
              metric_name = "RequestCount"

              dimensions {
                name  = "LoadBalancer"
                value = aws_lb.app.arn_suffix
              }

              dimensions {
                name  = "TargetGroup"
                value = aws_lb_target_group.app.arn_suffix
              }
            }
          }

          return_data = false
        }

        metrics {
          id    = "requests_green"
          label = "Requests, green target group"

          metric_stat {
            stat = "Sum"

            metric {
              namespace   = "AWS/ApplicationELB"
              metric_name = "RequestCount"

              dimensions {
                name  = "LoadBalancer"
                value = aws_lb.app.arn_suffix
              }

              dimensions {
                name  = "TargetGroup"
                value = one(aws_lb_target_group.green[*].arn_suffix)
              }
            }
          }

          return_data = false
        }

        metrics {
          id    = "tasks"
          label = "Running tasks"

          metric_stat {
            stat = "Average"

            metric {
              namespace   = "ECS/ContainerInsights"
              metric_name = "RunningTaskCount"

              dimensions {
                name  = "ClusterName"
                value = aws_ecs_cluster.main.name
              }

              dimensions {
                name  = "ServiceName"
                value = local.service_name
              }
            }
          }

          return_data = false
        }

        metrics {
          id          = "requests_per_task"
          label       = "Requests per task (both target groups)"
          expression  = "(FILL(requests_blue, 0) + FILL(requests_green, 0)) / tasks"
          return_data = true
        }
      }
    }
  }
}
