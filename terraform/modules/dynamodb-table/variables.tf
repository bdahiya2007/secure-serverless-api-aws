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

variable "enable_streams" {
  description = "Turn on DynamoDB Streams. Free to enable; required for a global table (replica_regions)."
  type        = bool
  default     = false
}

variable "stream_view_type" {
  description = "What each stream record carries. A global table needs NEW_AND_OLD_IMAGES."
  type        = string
  default     = "NEW_AND_OLD_IMAGES"

  validation {
    condition     = contains(["KEYS_ONLY", "NEW_IMAGE", "OLD_IMAGE", "NEW_AND_OLD_IMAGES"], var.stream_view_type)
    error_message = "stream_view_type must be KEYS_ONLY, NEW_IMAGE, OLD_IMAGE or NEW_AND_OLD_IMAGES."
  }
}

variable "replica_regions" {
  description = "Regions that hold a replica of the table (a DynamoDB global table, multi-region active/active). BILLED: every write is charged again in each replica region (replicated write units), plus storage there. Empty means a regular single-region table."
  type        = list(string)
  default     = []
}
