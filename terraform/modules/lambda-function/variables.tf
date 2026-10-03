variable "function_name" {
  description = "Name of the Lambda function. Also names the IAM role and log group."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{1,64}$", var.function_name))
    error_message = "function_name must be 1-64 characters: letters, numbers, hyphen or underscore."
  }
}

variable "description" {
  description = "Description of the function."
  type        = string
  default     = ""
}

variable "source_dir" {
  description = "Directory containing the function code. It is zipped as-is, except for test files."
  type        = string
}

variable "handler" {
  description = "Entry point, in the form <file>.<exported function>."
  type        = string
  default     = "index.handler"
}

variable "runtime" {
  description = "Lambda runtime. Node.js 24 is the latest generally available runtime (supported until Apr 2028); Node.js 26 is still in public preview."
  type        = string
  default     = "nodejs24.x"
}

variable "architecture" {
  description = "Instruction set: arm64 (Graviton, cheaper per ms) or x86_64."
  type        = string
  default     = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "architecture must be arm64 or x86_64."
  }
}

variable "memory_size" {
  description = "Memory in MB. CPU scales with memory."
  type        = number
  default     = 128

  validation {
    condition     = var.memory_size >= 128 && var.memory_size <= 10240
    error_message = "memory_size must be between 128 and 10240 MB."
  }
}

variable "timeout" {
  description = "Function timeout in seconds."
  type        = number
  default     = 10

  validation {
    condition     = var.timeout >= 1 && var.timeout <= 900
    error_message = "timeout must be between 1 and 900 seconds."
  }
}

variable "environment_variables" {
  description = "Environment variables for the function. Do not put secrets here."
  type        = map(string)
  default     = {}
}

variable "policy_statements" {
  description = "Least-privilege IAM statements for the function (logging is added automatically). Wildcard actions and resources are rejected."
  type = list(object({
    sid       = string
    actions   = list(string)
    resources = list(string)
  }))
  default = []

  validation {
    condition = alltrue(flatten([
      for s in var.policy_statements : concat(
        [for a in s.actions : a != "*" && !endswith(a, ":*")],
        [for r in s.resources : r != "*"]
      )
    ]))
    error_message = "Wildcard actions (\"*\" or \"service:*\") and the wildcard resource \"*\" are not allowed. Scope each statement to specific actions and ARNs."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention. Short retention keeps storage inside the free tier."
  type        = number
  default     = 14

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a value CloudWatch Logs supports."
  }
}

variable "permissions_boundary" {
  description = "ARN of a permissions boundary policy for the execution role (the ceiling for what the role can ever do, even if its own policy is widened). Null for none."
  type        = string
  default     = null
}

variable "enable_xray_tracing" {
  description = "Active X-Ray tracing. Adds a deliberate, narrow IAM exception: xray:PutTraceSegments and xray:PutTelemetryRecords do not support resource-level permissions, so they are granted on \"*\" (write-only, no read access)."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to all resources in the module."
  type        = map(string)
  default     = {}
}
