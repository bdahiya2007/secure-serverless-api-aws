output "table_name" {
  description = "Name of the DynamoDB table."
  value       = aws_dynamodb_table.this.name
}

output "table_arn" {
  description = "ARN of the DynamoDB table, for least-privilege IAM policies."
  value       = aws_dynamodb_table.this.arn
}

output "hash_key" {
  description = "Partition key attribute name."
  value       = aws_dynamodb_table.this.hash_key
}

output "range_key" {
  description = "Sort key attribute name."
  value       = aws_dynamodb_table.this.range_key
}
