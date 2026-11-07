# DNS failover for the app name (enable_dr_failover; docs/DR_Design_Decisions.md, decision 6). Both load balancers admit only the
# owner's address, so Route 53's own health checkers could not reach them. Instead the health check FOLLOWS A CLOUDWATCH ALARM
# on the number of healthy targets behind this Region's load balancer.
#
# If the whole Region is down, the alarm cannot be evaluated: CloudWatch has no data (the alarm treats missing data as breaching)
# and Route 53 treats an alarm with insufficient data as unhealthy. Either way the PRIMARY record is unhealthy and the name moves
# to the SECONDARY record, which the Region B stack creates.

resource "aws_cloudwatch_metric_alarm" "no_healthy_targets" {
  count = var.enable_dr_failover ? 1 : 0

  alarm_name          = "${var.project_name}-no-healthy-targets"
  alarm_description   = "No healthy targets behind the load balancer for 3 minutes. Drives the Route 53 failover health check."
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  treat_missing_data  = "breaching"

  # Healthy targets in the blue group plus, with blue/green, the green group (CodeDeploy moves traffic between them)
  metric_query {
    id          = "healthy"
    expression  = var.enable_blue_green ? "FILL(blue, 0) + FILL(green, 0)" : "FILL(blue, 0)"
    label       = "Healthy targets"
    return_data = true
  }

  metric_query {
    id = "blue"

    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HealthyHostCount"
      period      = 60
      stat        = "Maximum"

      dimensions = {
        LoadBalancer = aws_lb.app.arn_suffix
        TargetGroup  = aws_lb_target_group.app.arn_suffix
      }
    }
  }

  dynamic "metric_query" {
    for_each = var.enable_blue_green ? [1] : []

    content {
      id = "green"

      metric {
        namespace   = "AWS/ApplicationELB"
        metric_name = "HealthyHostCount"
        period      = 60
        stat        = "Maximum"

        dimensions = {
          LoadBalancer = aws_lb.app.arn_suffix
          TargetGroup  = one(aws_lb_target_group.green[*].arn_suffix)
        }
      }
    }
  }
}

resource "aws_route53_health_check" "primary" {
  count = var.enable_dr_failover ? 1 : 0

  type                            = "CLOUDWATCH_METRIC"
  cloudwatch_alarm_name           = aws_cloudwatch_metric_alarm.no_healthy_targets[0].alarm_name
  cloudwatch_alarm_region         = var.aws_region
  insufficient_data_health_status = "Unhealthy"

  tags = { Name = "${var.project_name}-primary" }
}
