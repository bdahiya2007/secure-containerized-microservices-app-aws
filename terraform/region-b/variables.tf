variable "aws_region" {
  description = "The recovery Region this stack builds in"
  type        = string
  default     = "us-west-2"
}

variable "primary_region" {
  description = "Region A, where the main stack and the Aurora primary run"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix for resource names; the same as the main stack, so names match across Regions where they should"
  type        = string
  default     = "product-service"
}

variable "vpc_cidr" {
  description = "Region B's VPC range. Different from Region A's (10.0.0.0/16) so the two never overlap if they are ever connected."
  type        = string
  default     = "10.1.0.0/16"
}

variable "allow_public_alb" {
  description = "Set to true to allow alb_ingress_cidr = 0.0.0.0/0, which opens the load balancer to the whole internet. Off by default, like the main stack."
  type        = bool
  default     = false
}

variable "alb_ingress_cidr" {
  description = "CIDR allowed to reach the load balancer on ports 443 and 80 (80 only redirects to HTTPS). Required, with no default, so it can't silently fall back to open. Use your own address as a /32; 0.0.0.0/0 is refused unless allow_public_alb is true."
  type        = string

  validation {
    condition     = can(cidrhost(var.alb_ingress_cidr, 0))
    error_message = "alb_ingress_cidr must be a valid CIDR block, for example 203.0.113.10/32."
  }
}

variable "state_bucket" {
  description = "The S3 bucket that holds the main stack's state (the same bucket as backend.hcl). Region B reads the main stack's outputs from it. Account-specific, so supply it in the untracked terraform.tfvars."
  type        = string
}

variable "main_state_key" {
  description = "The key of the main stack's state in that bucket"
  type        = string
  default     = "secure-containerized-microservices-app-aws/terraform.tfstate"
}

variable "aurora_min_capacity" {
  description = "Aurora Serverless v2 minimum capacity in ACUs for the secondary cluster. Low for a demo; the drill measures the replication lag at this setting."
  type        = number
  default     = 0.5
}

variable "aurora_max_capacity" {
  description = "Aurora Serverless v2 maximum capacity in ACUs for the secondary cluster"
  type        = number
  default     = 4
}

variable "enable_rds_logs" {
  description = "Export the secondary cluster's PostgreSQL log to CloudWatch Logs (14-day retention). Off by default."
  type        = bool
  default     = false
}

variable "app_domain" {
  description = "Region B's own name for the app (for example usw2.products.example.com): it lets Region B be tested directly before a failover. Keep the real value in the untracked terraform.tfvars."
  type        = string

  validation {
    condition     = endswith(var.app_domain, ".${var.hosted_zone_name}")
    error_message = "app_domain must be a name inside hosted_zone_name (for example usw2.products.example.com in example.com)."
  }
}

variable "hosted_zone_name" {
  description = "The existing public Route 53 hosted zone that holds app_domain (for example example.com). It is only read: this stack adds the certificate validation record and one alias record, and never changes the zone or other records."
  type        = string
}

variable "image_tag" {
  description = "The image tag Region B runs. Region A's pipeline moves :latest to every image that deployed; ECR replication copies it here."
  type        = string
  default     = "latest"
}

variable "desired_count" {
  description = "Tasks kept running in Region B. One is the pilot light: it proves the image, the replicated secret and the read-only database work together before a disaster. Scale it up by hand in a failover (docs/DR_Design_Decisions.md)."
  type        = number
  default     = 1
}

variable "db_name" {
  description = "The database name the app connects to; the same as the main stack"
  type        = string
  default     = "products"
}
