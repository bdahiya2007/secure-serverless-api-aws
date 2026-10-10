variable "name" {
  description = "Name of the IAM role API Gateway assumes to call DynamoDB."
  type        = string
}

variable "table_arn" {
  description = "ARN of the one DynamoDB table the role may read."
  type        = string
}

variable "actions" {
  description = "DynamoDB actions the role may perform. Read-only by design: only Query and GetItem are accepted."
  type        = list(string)
  default     = ["dynamodb:Query"]

  validation {
    condition     = length(var.actions) > 0 && alltrue([for a in var.actions : contains(["dynamodb:Query", "dynamodb:GetItem"], a)])
    error_message = "actions may only contain dynamodb:Query and dynamodb:GetItem. This role is read-only; no wildcards and no write actions."
  }
}

variable "permissions_boundary" {
  description = "ARN of the permissions boundary the pipeline requires on every role it creates."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to the role."
  type        = map(string)
  default     = {}
}
