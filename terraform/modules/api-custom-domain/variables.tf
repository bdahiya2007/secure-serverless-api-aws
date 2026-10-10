variable "domain_name" {
  description = "Fully qualified name for the API, for example api.example.com."
  type        = string
}

variable "zone_id" {
  description = "ID of the existing Route 53 hosted zone that contains the domain. Only certificate-validation records are added to it."
  type        = string
}

variable "rest_api_id" {
  description = "ID of the REST API to expose."
  type        = string
}

variable "stage_name" {
  description = "Stage of the REST API to map to the domain's root path."
  type        = string
}

variable "tags" {
  description = "Tags applied to the certificate and domain name."
  type        = map(string)
  default     = {}
}
