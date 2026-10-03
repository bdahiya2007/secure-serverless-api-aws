variable "name" {
  description = "Name of the DynamoDB table."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9_.-]{3,255}$", var.name))
    error_message = "Table name must be 3-255 characters: letters, numbers, underscore, hyphen or dot."
  }
}

variable "hash_key" {
  description = "Attribute name of the partition (hash) key."
  type        = string
}

variable "hash_key_type" {
  description = "Partition key type: S (string), N (number) or B (binary)."
  type        = string
  default     = "S"

  validation {
    condition     = contains(["S", "N", "B"], var.hash_key_type)
    error_message = "hash_key_type must be one of S, N or B."
  }
}

variable "range_key" {
  description = "Attribute name of the sort (range) key. Null for a partition-key-only table."
  type        = string
  default     = null
}

variable "range_key_type" {
  description = "Sort key type: S (string), N (number) or B (binary)."
  type        = string
  default     = "S"

  validation {
    condition     = contains(["S", "N", "B"], var.range_key_type)
    error_message = "range_key_type must be one of S, N or B."
  }
}

variable "deletion_protection_enabled" {
  description = "Block table deletion (free). Set to false before running terraform destroy."
  type        = bool
  default     = true
}

variable "enable_point_in_time_recovery" {
  description = "Continuous backups with restore to any second in the last 35 days. BILLED per GB, no free tier."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to the table."
  type        = map(string)
  default     = {}
}
