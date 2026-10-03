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
