variable "name" {
  description = "Name of the web ACL (also used for its CloudWatch metric names)."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{1,128}$", var.name))
    error_message = "name may contain only letters, numbers, hyphen and underscore (it becomes a metric name)."
  }
}

variable "resource_arn" {
  description = "ARN of the resource to protect, for example an API Gateway stage."
  type        = string
}

variable "rate_limit" {
  description = "Maximum requests per IP address within the evaluation window before further requests are blocked. WAF requires at least 10."
  type        = number
  default     = 100

  validation {
    condition     = var.rate_limit >= 10 && var.rate_limit <= 2000000000
    error_message = "rate_limit must be between 10 and 2,000,000,000."
  }
}

variable "evaluation_window_seconds" {
  description = "Time window over which requests are counted per IP."
  type        = number
  default     = 300

  validation {
    condition     = contains([60, 120, 300, 600], var.evaluation_window_seconds)
    error_message = "evaluation_window_seconds must be 60, 120, 300 or 600."
  }
}

variable "tags" {
  description = "Tags applied to the web ACL."
  type        = map(string)
  default     = {}
}
