variable "name" {
  description = "Name of the REST API."
  type        = string
}

variable "description" {
  description = "Description of the REST API."
  type        = string
  default     = ""
}

variable "stage_name" {
  description = "Stage name, which becomes the first path segment of the invoke URL."
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]+$", var.stage_name))
    error_message = "stage_name may contain only letters, numbers, hyphen and underscore."
  }
}

variable "routes" {
  description = <<-EOT
    Routes backed by Lambda proxy integrations, keyed by an alphanumeric name (used as the
    request model name). Each route is one path segment under the API root plus an HTTP method.
    authorization_type must not be NONE. Only AWS_IAM is supported until an authorizer is added.
    request_schema is an optional JSON Schema (draft 4) that API Gateway validates before invoking the Lambda.
  EOT
  type = map(object({
    path_part            = string
    http_method          = string
    lambda_function_name = string
    lambda_invoke_arn    = string
    authorization_type   = optional(string, "AWS_IAM")
    request_schema       = optional(string)
  }))

  validation {
    condition     = alltrue([for k in keys(var.routes) : can(regex("^[a-zA-Z0-9]+$", k))])
    error_message = "Route keys must be alphanumeric (they are used as API Gateway model names)."
  }

  validation {
    condition     = alltrue([for r in values(var.routes) : r.authorization_type == "AWS_IAM"])
    error_message = "authorization_type must be AWS_IAM. NONE is rejected on purpose; other authorizers are not implemented yet."
  }

  validation {
    condition     = alltrue([for r in values(var.routes) : contains(["GET", "POST", "PUT", "PATCH", "DELETE"], r.http_method)])
    error_message = "http_method must be one of GET, POST, PUT, PATCH, DELETE."
  }
}

variable "throttling_rate_limit" {
  description = "Steady-state requests per second allowed across the stage. Caps abuse and cost."
  type        = number
  default     = 5
}

variable "throttling_burst_limit" {
  description = "Burst capacity in requests."
  type        = number
  default     = 10
}

variable "tags" {
  description = "Tags applied to the API and stage."
  type        = map(string)
  default     = {}
}
