variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used for tagging."
  type        = string
  default     = "secure-serverless-api-aws"
}

variable "environment" {
  description = "Environment name, used for tagging."
  type        = string
  default     = "dev"
}
