output "health_check_ids" {
  description = "Health check ID per region (for example to simulate a failure with aws route53 update-health-check --inverted)."
  value       = { for k, h in aws_route53_health_check.this : k => h.id }
}
