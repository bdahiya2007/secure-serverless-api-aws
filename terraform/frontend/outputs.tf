output "site_url" {
  description = "The front end's address."
  value       = module.site.site_url
}

output "bucket_name" {
  description = "The private bucket the page's files are uploaded to (scripts/deploy-frontend.sh)."
  value       = module.site.bucket_name
}

output "distribution_id" {
  description = "The CloudFront distribution ID (cache invalidations)."
  value       = module.site.distribution_id
}

output "waf_enabled" {
  description = "Whether the (billed) web ACL is attached to the front end."
  value       = module.site.waf_enabled
}
