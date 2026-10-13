variable "name" {
  description = "Short name used for the resources (the origin access control, the response headers policy, the alarm and the optional web ACL)."
  type        = string
}

variable "bucket_name" {
  description = "Name of the private S3 bucket that holds the site. Bucket names are global; include something unique such as the account ID."
  type        = string
}

variable "domain_name" {
  description = "Fully qualified name of the site, for example orders.example.com. A dedicated ACM certificate and one DNS alias record are created for exactly this name."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.domain_name))
    error_message = "domain_name must be a lower-case fully qualified domain name."
  }
}

variable "zone_id" {
  description = "ID of the EXISTING Route 53 public hosted zone that contains domain_name. Only new records for domain_name (and the certificate validation) are added; existing records are never changed."
  type        = string
}

variable "price_class" {
  description = "CloudFront price class. PriceClass_100 (North America and Europe) is the cheapest."
  type        = string
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.price_class)
    error_message = "price_class must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}

variable "csp_connect_sources" {
  description = "Origins the page's JavaScript may call (the Content Security Policy connect-src): the API and the Cognito hosted domain, for example [\"https://abc.execute-api.us-east-1.amazonaws.com\", \"https://<prefix>.auth.<region>.amazoncognito.com\"]. 'self' is always allowed."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for o in var.csp_connect_sources : can(regex("^https://[a-z0-9.-]+(:[0-9]{1,5})?$", o))])
    error_message = "Each connect source must be an exact https origin with no path and no wildcard."
  }
}

variable "config" {
  description = "Public settings the page reads at start-up, written to config.json (for example the API URL, the Cognito hosted host and the browser client ID). Must contain NO secrets: everyone who loads the page can read it."
  type        = any
  default     = {}
}

variable "enable_waf" {
  description = "Attach a NEW web ACL (CloudFront scope) with a per-IP rate rule. COSTS about $6 a month (the ACL $5 plus one rule $1, billed hourly even when idle) with no free tier, and protects only the delivery of these static files, NOT the API. Off by default."
  type        = bool
  default     = false
}

variable "waf_rate_limit" {
  description = "Requests allowed per IP per 5 minutes before the web ACL blocks (when enable_waf is on). Minimum 10."
  type        = number
  default     = 100

  validation {
    condition     = var.waf_rate_limit >= 10
    error_message = "waf_rate_limit must be at least 10."
  }
}

variable "request_alarm_threshold" {
  description = "CloudWatch alarm (free) when the distribution serves more than this many requests in one hour: an early warning of a traffic flood. It has no action; check the console, or attach a notification later."
  type        = number
  default     = 10000
}

variable "tags" {
  description = "Tags applied to the resources."
  type        = map(string)
  default     = {}
}
