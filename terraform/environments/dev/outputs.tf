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
  description = "URL for POST /orders (requests must be SigV4-signed: authorization is AWS_IAM)."
  value       = "${module.orders_api.invoke_url}/orders"
}
