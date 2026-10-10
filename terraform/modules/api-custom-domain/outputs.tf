output "regional_domain_name" {
  description = "Regional API Gateway target name; the DNS record for the domain points here."
  value       = aws_api_gateway_domain_name.this.regional_domain_name
}

output "regional_zone_id" {
  description = "Hosted zone ID of the regional target (for alias records)."
  value       = aws_api_gateway_domain_name.this.regional_zone_id
}
