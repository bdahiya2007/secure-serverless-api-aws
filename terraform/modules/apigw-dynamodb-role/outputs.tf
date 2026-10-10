output "role_arn" {
  description = "ARN of the role, passed to the API Gateway integration as its credentials."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Name of the role."
  value       = aws_iam_role.this.name
}
