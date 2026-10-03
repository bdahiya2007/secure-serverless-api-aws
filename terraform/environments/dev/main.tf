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

module "orders_api" {
  source = "../../modules/rest-api"

  name        = "orders-api"
  description = "REST API for creating orders"
  stage_name  = var.environment

  routes = {
    CreateOrder = {
      path_part            = "orders"
      http_method          = "POST"
      lambda_function_name = module.save_order_function.function_name
      lambda_invoke_arn    = module.save_order_function.invoke_arn
      authorization_type   = "AWS_IAM" # swapped for the Cognito authorizer in a later step
      request_schema       = file("${path.module}/models/create-order.json")
    }
  }
}
