# CloudWatch dashboard for the Product Service: ECS capacity and task counts, and ALB traffic and errors.
#
# Metric choices:
# - CPUReservation and MemoryReservation are only published for ECS clusters that use EC2 container
#   instances, not for Fargate. Container Insights (enabled on the cluster) publishes the Fargate
#   equivalents, CpuReserved and MemoryReserved, and also DesiredTaskCount.
# - The service has no Lambda function and no API Gateway, so request Count and 4XX errors come from the
#   load balancer (RequestCount, HTTPCode_Target_4XX_Count).
#
# NOTE ON LAMBDA: requirement 5 also asks for Lambda Invocations and Errors metrics and for X-Ray tracing
# on the Lambda function. This project deliberately has no Lambda function (the service is a container on
# ECS Fargate), so there are no Lambda metrics to chart and no function to trace, and neither was added.
# The equivalents here are the ECS and ALB widgets below. If a Lambda is added later (for example a
# scheduled health check), add AWS/Lambda Invocations and Errors widgets and set
# tracing_config { mode = "Active" } on the function. X-Ray for the ECS tasks would need the X-Ray SDK in
# the app plus an X-Ray or ADOT sidecar and task-role permissions; it is not implemented.
locals {
  dash_cluster = aws_ecs_cluster.main.name
  dash_service = local.service_name
  dash_lb      = aws_lb.app.arn_suffix
  dash_tg      = aws_lb_target_group.app.arn_suffix
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = var.project_name

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "# ${var.project_name}\nECS on Fargate behind an Application Load Balancer. CPUReservation and MemoryReservation exist only for EC2-backed clusters, so this dashboard shows the Fargate equivalents from Container Insights (CpuReserved, MemoryReserved, DesiredTaskCount). There is no Lambda function in this service, so there are no Lambda metrics; request count and 4XX errors come from the ALB."
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 12
        height = 6
        properties = {
          title   = "ECS CPU: reserved and utilized (CPU units, 1024 = 1 vCPU)"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            ["ECS/ContainerInsights", "CpuReserved", "ClusterName", local.dash_cluster, "ServiceName", local.dash_service, { stat = "Average", label = "CPU reserved" }],
            ["ECS/ContainerInsights", "CpuUtilized", "ClusterName", local.dash_cluster, "ServiceName", local.dash_service, { stat = "Average", label = "CPU utilized" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 2
        width  = 12
        height = 6
        properties = {
          title   = "ECS memory: reserved and utilized (MB)"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            ["ECS/ContainerInsights", "MemoryReserved", "ClusterName", local.dash_cluster, "ServiceName", local.dash_service, { stat = "Average", label = "Memory reserved" }],
            ["ECS/ContainerInsights", "MemoryUtilized", "ClusterName", local.dash_cluster, "ServiceName", local.dash_service, { stat = "Average", label = "Memory utilized" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 12
        height = 6
        properties = {
          title   = "ECS tasks: desired, running and pending"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            ["ECS/ContainerInsights", "DesiredTaskCount", "ClusterName", local.dash_cluster, "ServiceName", local.dash_service, { stat = "Average", label = "Desired" }],
            ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", local.dash_cluster, "ServiceName", local.dash_service, { stat = "Average", label = "Running" }],
            ["ECS/ContainerInsights", "PendingTaskCount", "ClusterName", local.dash_cluster, "ServiceName", local.dash_service, { stat = "Average", label = "Pending" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 8
        width  = 12
        height = 6
        properties = {
          title   = "ECS service CPU and memory utilization (%), the values Auto Scaling tracks"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          yAxis   = { left = { min = 0, max = 100 } }
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", local.dash_cluster, "ServiceName", local.dash_service, { stat = "Average", label = "CPU %" }],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", local.dash_cluster, "ServiceName", local.dash_service, { stat = "Average", label = "Memory %" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 14
        width  = 12
        height = 6
        properties = {
          title   = "ALB request count (requests per minute)"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.dash_lb, { stat = "Sum", label = "Requests" }],
            ["AWS/ApplicationELB", "RequestCountPerTarget", "TargetGroup", local.dash_tg, "LoadBalancer", local.dash_lb, { stat = "Sum", label = "Requests per task (scaling metric)" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 14
        width  = 12
        height = 6
        properties = {
          title   = "ALB errors: 4XX and 5XX responses"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_4XX_Count", "LoadBalancer", local.dash_lb, { stat = "Sum", label = "4XX from the app" }],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", local.dash_lb, { stat = "Sum", label = "5XX from the app" }],
            ["AWS/ApplicationELB", "HTTPCode_ELB_4XX_Count", "LoadBalancer", local.dash_lb, { stat = "Sum", label = "4XX from the ALB" }],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", local.dash_lb, { stat = "Sum", label = "5XX from the ALB" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 20
        width  = 12
        height = 6
        properties = {
          title   = "ALB target response time (seconds)"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "TargetGroup", local.dash_tg, "LoadBalancer", local.dash_lb, { stat = "Average", label = "Average" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "TargetGroup", local.dash_tg, "LoadBalancer", local.dash_lb, { stat = "p95", label = "p95" }],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 20
        width  = 12
        height = 6
        properties = {
          title   = "ALB target health: healthy and unhealthy tasks"
          region  = var.aws_region
          view    = "timeSeries"
          stacked = false
          period  = 60
          metrics = [
            ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", local.dash_tg, "LoadBalancer", local.dash_lb, { stat = "Average", label = "Healthy" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", local.dash_tg, "LoadBalancer", local.dash_lb, { stat = "Average", label = "Unhealthy" }],
          ]
        }
      },
    ]
  })
}
