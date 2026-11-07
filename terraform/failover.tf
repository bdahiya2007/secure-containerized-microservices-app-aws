# DNS failover for the app name (enable_dr_failover; docs/DR_Design_Decisions.md, decision 6). Both load balancers admit only the
# owner's address, so Route 53's own health checkers could not reach them. Instead the health check FOLLOWS A CLOUDWATCH ALARM
# on the number of running tasks in this Region's service.
#
# If the whole Region is down, the alarm cannot be evaluated: CloudWatch has no data (the alarm treats missing data as breaching)
# and Route 53 treats an alarm with insufficient data as unhealthy. Either way the PRIMARY record is unhealthy and the name moves
# to the SECONDARY record, which the Region B stack creates.

resource "aws_cloudwatch_metric_alarm" "no_running_tasks" {
  count = var.enable_dr_failover ? 1 : 0

  alarm_name        = "${var.project_name}-no-running-tasks"
  alarm_description = "No running tasks in the service for 3 minutes. Drives the Route 53 failover health check."

  # One metric, one standard statistic, 3 of 3 periods: Route 53 supports no metric math, no extended statistics and no
  # "M out of N" alarms (found on the first real apply, when an alarm built from two target groups' healthy counts with
  # metric math was refused). Running tasks come from Container Insights, which is on for the cluster. This watches the tasks,
  # not the load balancer's view of them: a task that runs but fails its health check is replaced by ECS, and the alarm
  # only fires if the service has no task at all for 3 minutes, as when the Region is down or the service is scaled to zero.
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RunningTaskCount"
  statistic           = "Minimum"
  period              = 60
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  treat_missing_data  = "breaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.main.name
    ServiceName = local.service_name
  }
}

resource "aws_route53_health_check" "primary" {
  count = var.enable_dr_failover ? 1 : 0

  type                            = "CLOUDWATCH_METRIC"
  cloudwatch_alarm_name           = aws_cloudwatch_metric_alarm.no_running_tasks[0].alarm_name
  cloudwatch_alarm_region         = var.aws_region
  insufficient_data_health_status = "Unhealthy"

  tags = { Name = "${var.project_name}-primary" }
}
