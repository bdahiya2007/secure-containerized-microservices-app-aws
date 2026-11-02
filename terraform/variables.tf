variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "product-service"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "db_name" {
  type    = string
  default = "products"
}

variable "db_username" {
  type    = string
  default = "product_app"
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "image_tag" {
  description = "Image tag in ECR to deploy"
  type        = string
  default     = "latest"
}

variable "desired_count" {
  type    = number
  default = 2
}

variable "autoscaling_min_capacity" {
  description = "Fewest tasks Auto Scaling keeps running. Two keeps one task in each availability zone."
  type        = number
  default     = 2
}

variable "autoscaling_max_capacity" {
  description = "Most tasks Auto Scaling will run. Each task opens up to 10 database connections, so keep this within what the database accepts."
  type        = number
  default     = 4
}

variable "autoscaling_cpu_target" {
  description = "Average CPU utilization (percent) that Auto Scaling tries to hold"
  type        = number
  default     = 60
}

variable "autoscaling_requests_per_target" {
  description = "Requests per task per minute through the load balancer that Auto Scaling tries to hold"
  type        = number
  default     = 500
}

variable "log_retention_days" {
  description = "Days to keep ALB access logs (central bucket) and S3 access logs (their own bucket) before they expire"
  type        = number
  default     = 30
}

variable "cloudtrail_log_retention_days" {
  description = "Days to keep CloudTrail logs in the central log bucket before they expire"
  type        = number
  default     = 90
}

variable "enable_cloudtrail" {
  description = "Create a multi-region CloudTrail trail that writes to the central log bucket. Account-wide; the first trail's management events are free, a second costs about $2 per 100,000 events. Off by default (demo)."
  type        = bool
  default     = false
}

variable "enable_s3_access_logging" {
  description = "Record who reads or changes the central log bucket's files (S3 server access logs), in a separate small bucket. Cents a month. Off by default (demo)."
  type        = bool
  default     = false
}

variable "enable_rds_logs" {
  description = "Export the PostgreSQL and upgrade logs to CloudWatch Logs (14-day retention). About $0.50 per GB ingested, cents for a quiet database. Off by default (demo)."
  type        = bool
  default     = false
}

variable "allow_public_alb" {
  description = "Set to true to allow alb_ingress_cidr = 0.0.0.0/0, which opens the load balancer to the whole internet. Off by default, so an open load balancer is always a deliberate choice."
  type        = bool
  default     = false
}

variable "alb_ingress_cidr" {
  description = "CIDR allowed to reach the load balancer on port 80. Required, with no default, so it can't silently fall back to open. Use your own address as a /32 (for example 203.0.113.10/32); 0.0.0.0/0 is refused unless allow_public_alb is true."
  type        = string

  validation {
    condition     = can(cidrhost(var.alb_ingress_cidr, 0))
    error_message = "alb_ingress_cidr must be a valid CIDR block, for example 203.0.113.10/32."
  }
}

variable "enable_blue_green" {
  description = "Deploy with CodeDeploy blue/green (driven by GitHub Actions) instead of ECS rolling updates. Changing it replaces the ECS service (a short outage), so it is off by default. See docs/CICD.md."
  type        = bool
  default     = false
}

variable "codedeploy_deployment_config" {
  description = "How CodeDeploy shifts traffic to the new tasks (only used when enable_blue_green is true)"
  type        = string
  default     = "CodeDeployDefault.ECSLinear10PercentEvery1Minutes"
}

variable "codedeploy_blue_termination_minutes" {
  description = "Minutes to keep the old tasks running after traffic has moved, so a rollback is instant (only used when enable_blue_green is true)"
  type        = number
  default     = 5
}

variable "enable_fargate_spot" {
  description = "Run part of the service on Fargate Spot (discounted, can be interrupted with a 2-minute warning) using a capacity provider strategy. Changing it replaces the ECS service (a short outage), so it is off by default. See docs/Fargate_Spot.md."
  type        = bool
  default     = false
}

variable "fargate_base" {
  description = "Tasks that always run on on-demand Fargate (only used when enable_fargate_spot is true). At least 1, so the service keeps running when Spot capacity is reclaimed. The default of 2 matches the Auto Scaling minimum: two tasks of one provider are spread across Availability Zones, while one task per provider was not (docs/Fargate_Spot.md)."
  type        = number
  default     = 2

  validation {
    condition     = var.fargate_base >= 1 && var.fargate_base <= 100
    error_message = "fargate_base must be between 1 and 100: at least one on-demand task keeps the service available when Spot capacity is reclaimed."
  }
}

variable "fargate_weight" {
  description = "Relative share of the tasks above the base that run on on-demand Fargate (only used when enable_fargate_spot is true)"
  type        = number
  default     = 1

  validation {
    condition     = var.fargate_weight >= 0 && var.fargate_weight <= 1000
    error_message = "fargate_weight must be between 0 and 1000."
  }
}

variable "fargate_spot_weight" {
  description = "Relative share of the tasks above the base that run on Fargate Spot (only used when enable_fargate_spot is true). 3 with a fargate_weight of 1 means about three Spot tasks for every on-demand one."
  type        = number
  default     = 3

  validation {
    condition     = var.fargate_spot_weight >= 0 && var.fargate_spot_weight <= 1000
    error_message = "fargate_spot_weight must be between 0 and 1000."
  }

  validation {
    condition     = var.fargate_weight + var.fargate_spot_weight > 0
    error_message = "fargate_weight and fargate_spot_weight cannot both be 0: ECS rejects a strategy whose weights are all zero."
  }
}
