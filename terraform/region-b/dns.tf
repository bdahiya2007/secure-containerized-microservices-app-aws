# Region B's own HTTPS name. The hosted zone is only READ: this stack adds the certificate validation record and one alias record
# for app_domain, so a destroy removes only those and never the zone or anything else in it. A certificate is per Region, so
# this is a separate one from Region A's.

data "aws_route53_zone" "app" {
  name         = var.hosted_zone_name
  private_zone = false
}

resource "aws_acm_certificate" "app" {
  domain_name = var.app_domain
  # Also the main name: after a failover Route 53 answers it with this load balancer, which must present a certificate for it
  subject_alternative_names = var.failover_domain == "" ? [] : [var.failover_domain]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for o in aws_acm_certificate.app.domain_validation_options : o.domain_name => {
      name   = o.resource_record_name
      type   = o.resource_record_type
      record = o.resource_record_value
    }
  }

  zone_id         = data.aws_route53_zone.app.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.app.zone_id
  name    = var.app_domain
  type    = "A"

  alias {
    name                   = aws_lb.app.dns_name
    zone_id                = aws_lb.app.zone_id
    evaluate_target_health = true
  }
}

# The SECONDARY half of the failover pair for the main name. The PRIMARY (Region A, with its health check) is in the main stack.
# Route 53 answers with this record only when the primary's health check is unhealthy.
resource "aws_route53_record" "failover_secondary" {
  count = var.enable_failover_record ? 1 : 0

  zone_id        = data.aws_route53_zone.app.zone_id
  name           = var.failover_domain
  type           = "A"
  set_identifier = "secondary"

  failover_routing_policy {
    type = "SECONDARY"
  }

  alias {
    name                   = aws_lb.app.dns_name
    zone_id                = aws_lb.app.zone_id
    evaluate_target_health = true
  }
}
