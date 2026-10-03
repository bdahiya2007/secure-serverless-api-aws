module "orders_table" {
  source = "../../modules/dynamodb-table"

  name           = "Orders"
  hash_key       = "orderId"
  hash_key_type  = "S"
  range_key      = "itemId"
  range_key_type = "S"

  deletion_protection_enabled   = true
  enable_point_in_time_recovery = false # billed per GB; enable once real data matters
}
