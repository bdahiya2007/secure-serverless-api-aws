variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used for tagging."
  type        = string
  default     = "secure-serverless-api-aws"
}

variable "environment" {
  description = "Environment name, used for tagging."
  type        = string
  default     = "dev"
}

variable "enable_api_cache" {
  description = "Provision an API Gateway stage cache (0.5 GB) and cache GET responses for api_cache_ttl_seconds. COSTS by the hour even when idle (not free-tier eligible), and reads can be stale for up to the TTL after a write. Keep false unless demonstrating; apply with -var enable_api_cache=true, and re-apply without it to remove."
  type        = bool
  default     = false
}

variable "api_cache_ttl_seconds" {
  description = "Cache TTL used when enable_api_cache is true."
  type        = number
  default     = 300
}

variable "enable_waf" {
  description = "Attach an AWS WAF per-IP rate limit to the API. COSTS about $6/month (web ACL $5 + rule $1, billed hourly even when idle, plus $0.60 per million requests). Keep false unless demonstrating; apply with -var enable_waf=true, and re-apply without it to remove."
  type        = bool
  default     = false
}

variable "waf_rate_limit" {
  description = "Requests allowed per IP per 5 minutes before WAF blocks. Minimum 10."
  type        = number
  default     = 100
}

variable "app_role_boundary_name" {
  description = "Name of the permissions boundary policy created by terraform/bootstrap."
  type        = string
  default     = "serverless-api-pipeline-app-role-boundary"
}
