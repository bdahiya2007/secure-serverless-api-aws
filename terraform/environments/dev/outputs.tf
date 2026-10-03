output "orders_table_name" {
  description = "Name of the Orders DynamoDB table."
  value       = module.orders_table.table_name
}

output "orders_table_arn" {
  description = "ARN of the Orders DynamoDB table."
  value       = module.orders_table.table_arn
}

output "save_order_function_name" {
  description = "Name of the save-order Lambda function."
  value       = module.save_order_function.function_name
}

output "save_order_function_arn" {
  description = "ARN of the save-order Lambda function."
  value       = module.save_order_function.function_arn
}

output "create_order_url" {
  description = "URL for POST /orders (requires a Cognito ID token in the Authorization header)."
  value       = "${module.orders_api.invoke_url}/orders"
}

output "user_pool_id" {
  description = "Cognito user pool ID."
  value       = module.orders_user_pool.user_pool_id
}

output "user_pool_client_id" {
  description = "Cognito app client ID, used to sign in."
  value       = module.orders_user_pool.client_id
}

output "waf_enabled" {
  description = "Whether the (billed) WAF rate limit is attached to the API."
  value       = var.enable_waf
}

output "waf_web_acl_arn" {
  description = "ARN of the WAF web ACL, or null when WAF is disabled."
  value       = try(module.orders_api_waf[0].web_acl_arn, null)
}
