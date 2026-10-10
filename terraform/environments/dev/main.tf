data "aws_caller_identity" "current" {}

locals {
  # Created by terraform/bootstrap; the pipeline can only create roles that carry it.
  app_role_boundary_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.app_role_boundary_name}"
}

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

  # 512 MB chosen from a benchmark (scripts/benchmark, see README "Performance"): cold request 1.28 s to 0.51 s,
  # warm 70 ms to 11 ms versus 128 MB; cost stays inside the free tier.
  memory_size = 512

  enable_xray_tracing  = true # free tier covers learning volumes; set false to disable
  permissions_boundary = local.app_role_boundary_arn

  # Least privilege: write one item type to one table. No read, update or delete.
  policy_statements = [
    {
      sid       = "PutOrderItem"
      actions   = ["dynamodb:PutItem"]
      resources = [module.orders_table.table_arn]
    }
  ]
}

# Lambda-based alternative to the direct DynamoDB read, so both styles exist for the same operation and can be
# compared. Named with the save-order- prefix so the pipeline's IAM scope (save-order-*) covers its role and function.
module "get_order_function" {
  source = "../../modules/lambda-function"

  function_name = "save-order-lookup"
  description   = "Reads an order's items from DynamoDB (Lambda alternative to the direct integration)"
  source_dir    = "${path.root}/../../../src/get-order"
  handler       = "index.handler"
  memory_size   = 512 # same as save-order, so the comparison with the direct read is fair

  environment_variables = {
    TABLE_NAME = module.orders_table.table_name
  }

  # Least privilege: Query on one table. No write, no scan.
  policy_statements = [
    {
      sid       = "QueryOrderItems"
      actions   = ["dynamodb:Query"]
      resources = [module.orders_table.table_arn]
    }
  ]

  enable_xray_tracing  = true
  permissions_boundary = local.app_role_boundary_arn
}

module "orders_user_pool" {
  source = "../../modules/cognito-user-pool"

  name = "orders-api-users"
  tier = "LITE" # 10,000 monthly active users free; PLUS has no free tier

  allow_admin_create_user_only = true       # no self sign-up; create users with the CLI
  mfa_configuration            = "OPTIONAL" # app-based TOTP only (free); SMS MFA is billed
  deletion_protection_enabled  = true
}

# Role API Gateway assumes to read the Orders table directly. Read-only and scoped to this one table; it
# carries the pipeline's permissions boundary (the name matches the save-order-* pattern the pipeline may manage).
module "orders_read_role" {
  source = "../../modules/apigw-dynamodb-role"

  name                 = "save-order-api-read-role"
  table_arn            = module.orders_table.table_arn
  actions              = ["dynamodb:Query"]
  permissions_boundary = local.app_role_boundary_arn
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

    # Same read as GET /orders/{orderId}, done by a Lambda, for comparison. Its own top-level path avoids
    # shadowing the direct route's {orderId}.
    GetOrderViaLambda = {
      path_part            = "orders-via-lambda"
      child_path_part      = "{orderId}"
      http_method          = "GET"
      lambda_function_name = module.get_order_function.function_name
      lambda_invoke_arn    = module.get_order_function.invoke_arn
      authorization_type   = "COGNITO_USER_POOLS"
    }
  }

  # Reads skip Lambda: API Gateway calls DynamoDB itself and maps request and response with VTL templates.
  dynamodb_routes = {
    GetOrder = {
      parent_path_part     = "orders"
      path_part            = "{orderId}"
      http_method          = "GET"
      authorization_type   = "COGNITO_USER_POOLS"
      action               = "Query"
      credentials_role_arn = module.orders_read_role.role_arn
      path_parameters      = ["orderId"]
      request_template     = replace(file("${path.module}/templates/get-order.request.vtl"), "__TABLE_NAME__", module.orders_table.table_name)
      response_template    = file("${path.module}/templates/get-order.response.vtl")
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

module "orders_dashboard" {
  source = "../../modules/cloudwatch-dashboard"

  name          = "orders-api-${var.environment}"
  region        = var.aws_region
  api_name      = module.orders_api.api_name
  stage_name    = module.orders_api.stage_name
  function_name = module.save_order_function.function_name
}
