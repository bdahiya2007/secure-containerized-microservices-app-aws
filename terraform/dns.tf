# HTTPS and the Route 53 name (enable_https). All of it is off by default.
#
# The hosted zone already exists and holds other records (the owner's site and other projects). It is only READ here:
# this stack adds the certificate validation records and one alias record for app_domain, so a destroy removes only
# those and never the zone or anything else in it.

data "aws_route53_zone" "app" {
  count = var.enable_https ? 1 : 0

  name         = var.hosted_zone_name
  private_zone = false
}

# Free public certificate, proven by a DNS record in the same zone
resource "aws_acm_certificate" "app" {
  count = var.enable_https ? 1 : 0

  domain_name       = var.app_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = var.enable_https ? {
    for o in aws_acm_certificate.app[0].domain_validation_options : o.domain_name => {
      name   = o.resource_record_name
      type   = o.resource_record_type
      record = o.resource_record_value
    }
  } : {}

  zone_id         = data.aws_route53_zone.app[0].zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "app" {
  count = var.enable_https ? 1 : 0

  certificate_arn         = aws_acm_certificate.app[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# app_domain points at the load balancer. The alias is free and follows the load balancer's address.
resource "aws_route53_record" "app" {
  count = var.enable_https ? 1 : 0

  zone_id = data.aws_route53_zone.app[0].zone_id
  name    = var.app_domain
  type    = "A"

  alias {
    name                   = aws_lb.app.dns_name
    zone_id                = aws_lb.app.zone_id
    evaluate_target_health = true
  }
}
