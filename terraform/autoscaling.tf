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

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.app.arn_suffix}/${aws_lb_target_group.app.arn_suffix}"
    }
  }
}
