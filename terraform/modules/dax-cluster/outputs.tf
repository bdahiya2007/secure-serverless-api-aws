output "client_endpoint" {
  description = "Encrypted cluster endpoint for the DAX client (daxs://...), passed to the Lambda as DAX_ENDPOINT."
  value       = "daxs://${aws_dax_cluster.this.cluster_address}"
}

output "cluster_arn" {
  description = "ARN of the cluster, for the dax:* data-plane permissions of its clients."
  value       = aws_dax_cluster.this.arn
}

output "client_security_group_id" {
  description = "Security group to attach to the Lambda so it can reach the cluster."
  value       = aws_security_group.client.id
}
