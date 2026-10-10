output "rest_api_id" {
  description = "ID of the REST API."
  value       = aws_api_gateway_rest_api.this.id
}

output "execution_arn" {
  description = "Execution ARN, for IAM policies that allow callers to invoke the API."
  value       = aws_api_gateway_rest_api.this.execution_arn
}

output "invoke_url" {
  description = "Base invoke URL of the stage (append the route path, e.g. /orders)."
  value       = aws_api_gateway_stage.this.invoke_url
}

output "stage_name" {
  description = "Deployed stage name."
  value       = aws_api_gateway_stage.this.stage_name
}

output "stage_arn" {
  description = "ARN of the stage, for associating a WAF web ACL."
  value       = aws_api_gateway_stage.this.arn
}

output "cache_enabled" {
  description = "Whether the (billed) stage cache is provisioned."
  value       = var.cache_enabled
}

output "api_name" {
  description = "Name of the REST API (the ApiName metric dimension)."
  value       = aws_api_gateway_rest_api.this.name
}
