variable "name" {
  description = "Cluster name (DAX allows at most 20 characters). Also prefixes the roles and security groups."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,19}$", var.name))
    error_message = "name must start with a letter and be 1-20 characters of lowercase letters, numbers and hyphens."
  }
}

variable "table_arn" {
  description = "ARN of the one DynamoDB table DAX may read."
  type        = string
}

variable "vpc_id" {
  description = "VPC the cluster, its clients and the logs endpoint live in."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the cluster and the logs endpoint. One subnet is enough for a single-node demo cluster."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 1
    error_message = "At least one subnet is required."
  }
}

variable "node_type" {
  description = "DAX node type. BILLED per node per hour (about $0.04 for the small types); there is no free tier."
  type        = string
  default     = "dax.t3.small"
}

variable "replication_factor" {
  description = "Number of nodes. One is for demos only; AWS recommends at least three, in different Availability Zones, for high availability. Each node is billed."
  type        = number
  default     = 1

  validation {
    condition     = var.replication_factor >= 1 && var.replication_factor <= 10
    error_message = "replication_factor must be between 1 and 10."
  }
}

variable "query_ttl_seconds" {
  description = "How long a cached Query result is served. Writes do not invalidate it, so this is how stale a read can be."
  type        = number
  default     = 60

  validation {
    condition     = var.query_ttl_seconds >= 1
    error_message = "query_ttl_seconds must be at least 1."
  }
}

variable "record_ttl_seconds" {
  description = "How long a cached item (GetItem) is served."
  type        = number
  default     = 60

  validation {
    condition     = var.record_ttl_seconds >= 1
    error_message = "record_ttl_seconds must be at least 1."
  }
}

variable "create_logs_endpoint" {
  description = "Create a CloudWatch Logs interface endpoint so a Lambda inside the VPC can write logs (it has no internet access). BILLED per hour (about $0.01) plus data."
  type        = bool
  default     = true
}

variable "permissions_boundary" {
  description = "ARN of the permissions boundary the pipeline requires on every role it creates."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to the resources."
  type        = map(string)
  default     = {}
}
