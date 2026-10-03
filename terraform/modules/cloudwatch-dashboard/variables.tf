variable "name" {
  description = "Dashboard name. The first 3 custom dashboards per account are free; each additional one is billed."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{1,255}$", var.name))
    error_message = "name may contain only letters, numbers, hyphen and underscore."
  }
}

variable "region" {
  description = "Region the metrics are read from."
  type        = string
}

variable "api_name" {
  description = "API Gateway REST API name (ApiName dimension)."
  type        = string
}

variable "stage_name" {
  description = "API Gateway stage name (Stage dimension)."
  type        = string
}

variable "function_name" {
  description = "Lambda function name (FunctionName dimension)."
  type        = string
}

variable "period_seconds" {
  description = "Metric aggregation period."
  type        = number
  default     = 300

  validation {
    condition     = contains([60, 300, 900, 3600], var.period_seconds)
    error_message = "period_seconds must be 60, 300, 900 or 3600."
  }
}
