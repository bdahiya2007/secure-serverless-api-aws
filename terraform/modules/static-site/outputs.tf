output "bucket_name" {
  description = "Name of the private bucket the page's files are uploaded to."
  value       = aws_s3_bucket.this.id
}

output "distribution_id" {
  description = "ID of the CloudFront distribution (for cache invalidations)."
  value       = aws_cloudfront_distribution.this.id
}

output "distribution_domain" {
  description = "The distribution's own *.cloudfront.net name."
  value       = aws_cloudfront_distribution.this.domain_name
}

output "site_url" {
  description = "The site's address."
  value       = "https://${var.domain_name}/"
}

output "waf_enabled" {
  description = "Whether the (billed) web ACL is attached."
  value       = var.enable_waf
}
