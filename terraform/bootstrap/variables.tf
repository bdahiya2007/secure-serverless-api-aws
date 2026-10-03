variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used for tagging."
  type        = string
  default     = "secure-serverless-api-aws"
}

variable "name_prefix" {
  description = "Prefix for the pipeline's own IAM resources (deploy role, boundary policy)."
  type        = string
  default     = "serverless-api-pipeline"
}

variable "github_owner" {
  description = "GitHub user or organization that owns the repository."
  type        = string
  default     = "bdahiya2007"
}

variable "github_owner_id" {
  description = "Immutable numeric owner ID (gh api users/<owner> --jq .id). Part of the OIDC sub claim, so a renamed or recreated account cannot match."
  type        = string
  default     = "5674538"
}

variable "github_repository" {
  description = "Repository name (no owner)."
  type        = string
  default     = "secure-serverless-api-aws"
}

variable "github_repository_id" {
  description = "Immutable numeric repository ID (gh api repos/<owner>/<repo> --jq .id)."
  type        = string
  default     = "1403639182"
}

variable "github_branch" {
  description = "Branch whose workflow runs may assume the deploy role."
  type        = string
  default     = "main"
}

variable "github_environment" {
  description = "GitHub environment (with required reviewers) whose jobs may assume the deploy role."
  type        = string
  default     = "production"
}

variable "state_key_prefix" {
  description = "Object key prefix in the state bucket that the deploy role may read and write."
  type        = string
  default     = "dev/"
}

variable "orders_table_name" {
  description = "DynamoDB table the pipeline manages and that application roles may use."
  type        = string
  default     = "Orders"
}

variable "lambda_function_name" {
  description = "Lambda function the pipeline manages."
  type        = string
  default     = "save-order"
}

variable "app_role_prefix" {
  description = "Name prefix of application IAM roles the pipeline may create (each must carry the boundary)."
  type        = string
  default     = "save-order"
}

variable "state_noncurrent_version_days" {
  description = "Days to keep old state versions (versioning is on). Bounds storage cost."
  type        = number
  default     = 90
}

variable "block_public_access_account_wide" {
  description = "Turn on S3 Block Public Access for the whole account (free). Safe only if no bucket intentionally serves public content; the buckets were audited before enabling this."
  type        = bool
  default     = true
}
