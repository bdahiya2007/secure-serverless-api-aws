output "deploy_role_arn" {
  description = "Set as the AWS_DEPLOY_ROLE_ARN GitHub repository secret."
  value       = aws_iam_role.deploy.arn
}

output "app_role_boundary_arn" {
  description = "Permissions boundary every application role must carry (set on the Lambda module)."
  value       = aws_iam_policy.boundary.arn
}

output "state_bucket" {
  description = "Terraform state bucket (use in environments/dev/backend.tf)."
  value       = aws_s3_bucket.state.bucket
}
