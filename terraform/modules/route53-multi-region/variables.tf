variable "zone_id" {
  description = "ID of the existing Route 53 hosted zone."
  type        = string
}

variable "domain_name" {
  description = "The name that clients use, for example api.example.com. Must not already have a record of type A."
  type        = string
}

variable "endpoints" {
  description = "One entry per region, keyed by the AWS region name (latency routing uses it): the custom domain's regional target, and the host and path of the unauthenticated health route."
  type = map(object({
    target_name    = string
    target_zone_id = string
    health_host    = string
    health_path    = string
  }))

  validation {
    condition     = length(var.endpoints) >= 2
    error_message = "Provide at least two regions."
  }
}

variable "tags" {
  description = "Tags applied to the health checks."
  type        = map(string)
  default     = {}
}
