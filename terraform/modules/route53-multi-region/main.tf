# Active/active DNS for one name: a latency-based alias record per region, each guarded by a Route 53 health check. A client
# is sent to the region with the lowest latency, and a region whose health check fails is dropped from the answers.
# Records are added for the one name given and nothing else in the zone is touched.
#
# BILLED: each health check is a monthly charge (prorated) with no free tier; HTTPS checks cost more than the basic one.

resource "aws_route53_health_check" "this" {
  for_each = var.endpoints

  type              = "HTTPS"
  fqdn              = each.value.health_host
  port              = 443
  resource_path     = each.value.health_path
  request_interval  = 30
  failure_threshold = 3
  enable_sni        = true

  tags = merge(var.tags, { Name = "${var.domain_name}-${each.key}" })
}

resource "aws_route53_record" "this" {
  for_each = var.endpoints

  zone_id         = var.zone_id
  name            = var.domain_name
  type            = "A"
  set_identifier  = each.key
  health_check_id = aws_route53_health_check.this[each.key].id

  latency_routing_policy {
    region = each.key
  }

  alias {
    name                   = each.value.target_name
    zone_id                = each.value.target_zone_id
    evaluate_target_health = false # health comes from the health check; API Gateway alias targets do not report health
  }
}
