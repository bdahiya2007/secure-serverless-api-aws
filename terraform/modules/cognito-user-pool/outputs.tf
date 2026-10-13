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

output "hosted_domain" {
  description = "Host name of the hosted sign-in pages, or null when the hosted UI is off."
  value       = local.hosted_ui ? "${aws_cognito_user_pool_domain.this[0].domain}.auth.${data.aws_region.current.region}.amazoncognito.com" : null
}

output "federated_client_id" {
  description = "ID of the browser app client (Google sign-in), or null when federated sign-in is off."
  value       = try(aws_cognito_user_pool_client.federated[0].id, null)
}

output "browser_client_id" {
  description = "ID of the public browser app client (code flow with PKCE, username and password on the hosted pages), or null when browser_callback_urls is empty."
  value       = try(aws_cognito_user_pool_client.browser[0].id, null)
}
