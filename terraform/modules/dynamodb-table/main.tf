resource "aws_dynamodb_table" "this" {
  name = var.name

  # On-demand capacity: no read/write capacity to provision or manage.
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = var.hash_key
  range_key = var.range_key

  attribute {
    name = var.hash_key
    type = var.hash_key_type
  }

  dynamic "attribute" {
    for_each = var.range_key == null ? [] : [var.range_key]

    content {
      name = attribute.value
      type = var.range_key_type
    }
  }

  deletion_protection_enabled = var.deletion_protection_enabled

  # Encryption at rest is always on. Omitting server_side_encryption keeps the
  # default AWS-owned key, which is free. Setting `enabled = true` here would
  # switch to the AWS-managed KMS key, and a customer-managed key is billed
  # per month, so neither is used until explicitly approved.

  point_in_time_recovery {
    enabled = var.enable_point_in_time_recovery
  }

  tags = var.tags
}
