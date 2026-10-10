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

  # DynamoDB Streams records every change. Enabling it is free (reading the stream is billed, and nothing here reads it),
  # and a global table needs it with both the old and new image of each item.
  stream_enabled   = var.enable_streams
  stream_view_type = var.enable_streams ? var.stream_view_type : null

  # Global table (multi-region, active/active): each replica is a full writable copy in another region, kept in sync by
  # DynamoDB. Every write is billed again in each replica region (replicated write units), and storage is billed there too.
  # Replicas are not deletion protected, so that switching the feature off can remove them.
  dynamic "replica" {
    for_each = toset(var.replica_regions)

    content {
      region_name                 = replica.value
      point_in_time_recovery      = var.enable_point_in_time_recovery
      deletion_protection_enabled = false
      propagate_tags              = true
    }
  }

  lifecycle {
    precondition {
      condition     = length(var.replica_regions) == 0 || (var.enable_streams && var.stream_view_type == "NEW_AND_OLD_IMAGES")
      error_message = "Replicas (a global table) need enable_streams = true and stream_view_type = NEW_AND_OLD_IMAGES."
    }
  }

  tags = var.tags
}
