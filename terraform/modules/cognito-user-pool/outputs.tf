output "user_pool_id" {
  description = "ID of the user pool."
  value       = aws_cognito_user_pool.this.id
}

output "user_pool_arn" {
  description = "ARN of the user pool, used by the API Gateway authorizer."
  value       = aws_cognito_user_pool.this.arn
}

output "client_id" {
  description = "ID of the public app client."
  value       = aws_cognito_user_pool_client.this.id
}
