# Region B's network: the same shape and security posture as Region A (docs/DR_Design_Decisions.md, decision 7): two zones,
# public subnets for the load balancer and the NAT gateway, private subnets for the tasks and the database, no public IPs on
# tasks, security groups chained internet -> ALB -> app -> database.

locals {
  name = "${var.project_name}-b"
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)
}

# Standard zones only, so the result can't silently change if a Local or Wavelength zone is enabled on the account
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name}-vpc" }
}

# Take over the VPC's default security group and give it no rules, so nothing can use it by accident
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.name}-public-${count.index}" }
}

resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.azs[count.index]
  tags              = { Name = "${local.name}-private-${count.index}" }
}

# One NAT gateway keeps the session cheap, as in Region A
resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# Free S3 gateway endpoint: ECR image layers come from S3, so pulls stay off the NAT gateway
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = { Name = "${local.name}-s3-endpoint" }
}

# ---- Security groups: internet -> ALB -> app -> database ----
resource "aws_security_group" "alb" {
  #checkov:skip=CKV2_AWS_5: attached by the load balancer, the ECS task and the Aurora cluster added in pieces 3b and 3c; remove this exception there
  name_prefix = "${local.name}-alb-"
  description = "Application Load Balancer (Region B): HTTPS from the allowed CIDR, port 80 only to redirect"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from the allowed CIDR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.alb_ingress_cidr]
  }

  ingress {
    description = "HTTP from the allowed CIDR, only to redirect to HTTPS"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.alb_ingress_cidr]
  }

  egress {
    description = "Forward to the app tasks on port 3000 inside the VPC"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  lifecycle {
    create_before_destroy = true

    # An open load balancer must be a deliberate choice, never a default
    precondition {
      condition     = var.allow_public_alb || var.alb_ingress_cidr != "0.0.0.0/0"
      error_message = "alb_ingress_cidr is 0.0.0.0/0, which opens the load balancer to the whole internet. Set it to your own address (for example 203.0.113.10/32), or set allow_public_alb = true if you really want a public load balancer."
    }
  }
}

resource "aws_security_group" "app" {
  #checkov:skip=CKV2_AWS_5: attached by the load balancer, the ECS task and the Aurora cluster added in pieces 3b and 3c; remove this exception there
  name_prefix = "${local.name}-app-"
  description = "ECS tasks (Region B): port 3000 from the load balancer only, outbound via the NAT gateway"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "App port 3000 from the load balancer security group"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  # No inline egress: the database group refers back to this group, so inline rules would create a dependency cycle
  lifecycle { create_before_destroy = true }
}

# Outbound is limited to what the tasks need: HTTPS to AWS services and PostgreSQL to the database group
resource "aws_vpc_security_group_egress_rule" "app_https" {
  security_group_id = aws_security_group.app.id
  description       = "HTTPS to AWS service endpoints (ECR, Secrets Manager, CloudWatch Logs) via the NAT gateway"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "app_postgres" {
  security_group_id            = aws_security_group.app.id
  description                  = "PostgreSQL to the database security group"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.db.id
}

resource "aws_security_group" "db" {
  #checkov:skip=CKV2_AWS_5: attached by the load balancer, the ECS task and the Aurora cluster added in pieces 3b and 3c; remove this exception there
  name_prefix = "${local.name}-db-"
  description = "Aurora secondary (Region B): port 5432 from the app security group only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from the app security group"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  lifecycle { create_before_destroy = true }
}
