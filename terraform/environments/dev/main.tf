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

module "save_order_function" {
  source = "../../modules/lambda-function"

  function_name = "save-order"
  description   = "Saves a single order item to the Orders DynamoDB table"
  source_dir    = "${path.root}/../../../src/save-order"
  handler       = "index.handler"

  environment_variables = {
    TABLE_NAME = module.orders_table.table_name
  }

  # Least privilege: write one item type to one table. No read, update or delete.
  policy_statements = [
    {
      sid       = "PutOrderItem"
      actions   = ["dynamodb:PutItem"]
      resources = [module.orders_table.table_arn]
    }
  ]
}

module "orders_user_pool" {
  source = "../../modules/cognito-user-pool"

  name = "orders-api-users"
  tier = "LITE" # 10,000 monthly active users free; PLUS has no free tier

  allow_admin_create_user_only = true       # no self sign-up; create users with the CLI
  mfa_configuration            = "OPTIONAL" # app-based TOTP only (free); SMS MFA is billed
  deletion_protection_enabled  = true
}

module "orders_api" {
  source = "../../modules/rest-api"

  name        = "orders-api"
  description = "REST API for creating orders"
  stage_name  = var.environment

  cognito_user_pool_arns = [module.orders_user_pool.user_pool_arn]

  routes = {
    CreateOrder = {
      path_part            = "orders"
      http_method          = "POST"
      lambda_function_name = module.save_order_function.function_name
      lambda_invoke_arn    = module.save_order_function.invoke_arn
      authorization_type   = "COGNITO_USER_POOLS"
      request_schema       = file("${path.module}/models/create-order.json")
    }
  }
}

# Optional and OFF by default: a web ACL is billed hourly even when idle (about $6/month).
module "orders_api_waf" {
  count  = var.enable_waf ? 1 : 0
  source = "../../modules/waf-rate-limit"

  name         = "orders-api-waf"
  resource_arn = module.orders_api.stage_arn
  rate_limit   = var.waf_rate_limit
}
