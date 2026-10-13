variable "project" {
  description = "Project name, used for tagging."
  type        = string
  default     = "secure-serverless-api-aws"
}

variable "domain_name" {
  description = "Fully qualified name of the front end, for example orders.example.com. It must be inside route53_zone_name, must not be the zone itself or www, and must not already have a DNS record. Set it in terraform.tfvars (git-ignored); it is not committed."
  type        = string
}

variable "route53_zone_name" {
  description = "Name of the EXISTING Route 53 public hosted zone that contains domain_name, for example example.com. Only new records for domain_name (and certificate validation) are added; existing records are never changed."
  type        = string
}

variable "state_bucket" {
  description = "Name of the Terraform state bucket (it contains the account ID, so it is not committed). Used to read the dev stack's outputs: the API URL, the Cognito sign-in host and client, and the CORS origins."
  type        = string
}

variable "dev_state_key" {
  description = "Key of the dev stack's state in the state bucket."
  type        = string
  default     = "dev/terraform.tfstate"
}

variable "price_class" {
  description = "CloudFront price class. PriceClass_100 (North America and Europe) is the cheapest."
  type        = string
  default     = "PriceClass_100"
}

variable "enable_waf" {
  description = "Attach a NEW web ACL with a per-IP rate rule to the front end's distribution. COSTS about $6 a month (billed hourly even when idle, no free tier) and protects only the static files, not the API (the API has its own enable_waf switch in the dev stack). Off by default."
  type        = bool
  default     = false
}

variable "waf_rate_limit" {
  description = "Requests allowed per IP per 5 minutes before the web ACL blocks, when enable_waf is on."
  type        = number
  default     = 100
}

variable "request_alarm_threshold" {
  description = "Free CloudWatch alarm when the distribution serves more than this many requests in one hour (an early warning of a traffic flood)."
  type        = number
  default     = 10000
}
