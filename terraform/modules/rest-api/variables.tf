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
    request model name). Each route is one path segment under the API root plus an HTTP method, and may add
    one child segment with child_path_part (for example path_part "orders-via-lambda" and child_path_part
    "{orderId}" gives /orders-via-lambda/{orderId}).
    authorization_type must be AWS_IAM or COGNITO_USER_POOLS; NONE is rejected. COGNITO_USER_POOLS
    needs cognito_user_pool_arns.
    request_schema is an optional JSON Schema (draft 4) that API Gateway validates before invoking the Lambda.
  EOT
  type = map(object({
    path_part            = string
    http_method          = string
    lambda_function_name = string
    lambda_invoke_arn    = string
    authorization_type   = optional(string, "AWS_IAM")
    request_schema       = optional(string)
    child_path_part      = optional(string)
  }))

  validation {
    condition     = alltrue([for r in values(var.routes) : r.child_path_part == null || can(regex("^[A-Za-z0-9._{}-]+$", r.child_path_part))])
    error_message = "child_path_part may contain only letters, numbers, '.', '_', '-' and {braces} for a path parameter."
  }

  validation {
    condition     = alltrue([for k in keys(var.routes) : can(regex("^[a-zA-Z0-9]+$", k))])
    error_message = "Route keys must be alphanumeric (they are used as API Gateway model names)."
  }

  validation {
    condition     = alltrue([for r in values(var.routes) : contains(["AWS_IAM", "COGNITO_USER_POOLS"], r.authorization_type)])
    error_message = "authorization_type must be AWS_IAM or COGNITO_USER_POOLS. NONE is rejected on purpose."
  }

  validation {
    condition     = !anytrue([for r in values(var.routes) : r.authorization_type == "COGNITO_USER_POOLS"]) || length(var.cognito_user_pool_arns) > 0
    error_message = "Routes using COGNITO_USER_POOLS need at least one ARN in cognito_user_pool_arns."
  }

  validation {
    condition     = alltrue([for r in values(var.routes) : contains(["GET", "POST", "PUT", "PATCH", "DELETE"], r.http_method)])
    error_message = "http_method must be one of GET, POST, PUT, PATCH, DELETE."
  }
}

variable "dynamodb_routes" {
  description = <<-EOT
    Read-only routes that API Gateway answers by calling DynamoDB itself (an AWS service integration, no Lambda).
    Each is a child path under one of the Lambda routes' path parts, for example orders/{orderId}, keyed by an
    alphanumeric name. action is limited to the read actions Query and GetItem. request_template turns the HTTP
    request into DynamoDB's JSON request; response_template turns DynamoDB's typed JSON into the client response
    and may set $context.responseOverride.status. DynamoDB errors are never passed through: they are replaced by
    static 400 and 500 bodies. NONE authorization is rejected, as for routes.
  EOT
  type = map(object({
    parent_path_part     = string
    path_part            = string
    http_method          = optional(string, "GET")
    authorization_type   = optional(string, "COGNITO_USER_POOLS")
    action               = string
    credentials_role_arn = string
    path_parameters      = list(string)
    request_template     = string
    response_template    = string
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.dynamodb_routes) : can(regex("^[a-zA-Z0-9]+$", k))])
    error_message = "dynamodb_routes keys must be alphanumeric."
  }

  validation {
    condition     = alltrue([for r in values(var.dynamodb_routes) : contains(["Query", "GetItem"], r.action)])
    error_message = "action must be Query or GetItem: direct integrations are read-only."
  }

  validation {
    condition     = alltrue([for r in values(var.dynamodb_routes) : r.http_method == "GET"])
    error_message = "dynamodb_routes only support GET."
  }

  validation {
    condition     = alltrue([for r in values(var.dynamodb_routes) : contains(["AWS_IAM", "COGNITO_USER_POOLS"], r.authorization_type)])
    error_message = "authorization_type must be AWS_IAM or COGNITO_USER_POOLS. NONE is rejected on purpose."
  }

  validation {
    condition     = !anytrue([for r in values(var.dynamodb_routes) : r.authorization_type == "COGNITO_USER_POOLS"]) || length(var.cognito_user_pool_arns) > 0
    error_message = "dynamodb_routes using COGNITO_USER_POOLS need at least one ARN in cognito_user_pool_arns."
  }

  validation {
    condition     = alltrue([for r in values(var.dynamodb_routes) : contains([for x in values(var.routes) : x.path_part], r.parent_path_part)])
    error_message = "parent_path_part must be the path_part of one of the Lambda routes."
  }

  validation {
    condition     = alltrue([for r in values(var.dynamodb_routes) : can(regex("^[A-Za-z0-9._{}-]+$", r.path_part))])
    error_message = "path_part may contain only letters, numbers, '.', '_', '-' and {braces} for a path parameter."
  }
}

variable "cognito_user_pool_arns" {
  description = "User pool ARNs for the Cognito authorizer. The authorizer is created only when this is non-empty."
  type        = list(string)
  default     = []
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
