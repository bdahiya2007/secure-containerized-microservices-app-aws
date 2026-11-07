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
