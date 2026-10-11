# ---------------------------------------------------------------------------
# Optional multi-region active/active (DynamoDB global table + a second API stack + Route 53 latency routing).
# OFF by default: it bills (replicated writes and storage, a second stack, Route 53 health checks).
#
#   client -> Route 53 (latency, health-checked) -> API Gateway -> Lambda -> Orders replica in the same region
#
# The Orders replica itself is declared on the table module (replica_regions). Sign-in stays with the ONE Cognito user pool
# in the primary region: the second API validates tokens against that pool, so new sign-ins depend on the primary region.
# IAM names are global, so the second region's roles and functions carry a -dr suffix (still inside the save-order-* scope).
# ---------------------------------------------------------------------------

locals {
  dr_enabled   = var.enable_multi_region
  dr_table_arn = "arn:aws:dynamodb:${var.dr_region}:${data.aws_caller_identity.current.account_id}:table/${module.orders_table.table_name}"
}

data "aws_route53_zone" "this" {
  count = local.dr_enabled ? 1 : 0

  name         = var.route53_zone_name
  private_zone = false
}

# Stops the plan early if the name is outside the zone.
resource "terraform_data" "multi_region_check" {
  count = local.dr_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = endswith(var.multi_region_domain, ".${trimsuffix(var.route53_zone_name, ".")}")
      error_message = "multi_region_domain must be a name inside route53_zone_name, for example api.example.com in example.com."
    }
  }
}

module "dr_save_order" {
  count     = local.dr_enabled ? 1 : 0
  source    = "../../modules/lambda-function"
  providers = { aws = aws.dr }

  function_name = "save-order-dr"
  description   = "Saves a single order item to the Orders replica in the second region"
  source_dir    = "${path.root}/../../../src/save-order"
  handler       = "index.handler"

  environment_variables = { TABLE_NAME = module.orders_table.table_name }

  memory_size          = 512
  enable_xray_tracing  = true
  permissions_boundary = local.app_role_boundary_arn

  policy_statements = [
    {
      sid       = "PutOrderItem"
      actions   = ["dynamodb:PutItem"]
      resources = [local.dr_table_arn]
    }
  ]

  depends_on = [module.orders_table]
}

module "dr_get_order" {
  count     = local.dr_enabled ? 1 : 0
  source    = "../../modules/lambda-function"
  providers = { aws = aws.dr }

  function_name = "save-order-lookup-dr"
  description   = "Reads an order's items from the Orders replica in the second region"
  source_dir    = "${path.root}/../../../src/get-order"
  handler       = "index.handler"
  memory_size   = 512

  environment_variables = { TABLE_NAME = module.orders_table.table_name }

  policy_statements = [
    {
      sid       = "QueryOrderItems"
      actions   = ["dynamodb:Query"]
      resources = [local.dr_table_arn]
    }
  ]

  enable_xray_tracing  = true
  permissions_boundary = local.app_role_boundary_arn

  depends_on = [module.orders_table]
}

module "dr_read_role" {
  count     = local.dr_enabled ? 1 : 0
  source    = "../../modules/apigw-dynamodb-role"
  providers = { aws = aws.dr }

  name                 = "save-order-api-read-role-dr"
  table_arn            = local.dr_table_arn
  actions              = ["dynamodb:Query"]
  permissions_boundary = local.app_role_boundary_arn

  depends_on = [module.orders_table]
}

module "dr_api" {
  count     = local.dr_enabled ? 1 : 0
  source    = "../../modules/rest-api"
  providers = { aws = aws.dr }

  name        = "orders-api"
  description = "REST API for creating orders (second region)"
  stage_name  = var.environment

  # The primary region's pool, plus the second region's pool when federated sign-in is on (see federated-signin.tf).
  cognito_user_pool_arns = local.api_user_pool_arns

  enable_health_route = true

  routes = {
    CreateOrder = {
      path_part            = "orders"
      http_method          = "POST"
      lambda_function_name = module.dr_save_order[0].function_name
      lambda_invoke_arn    = module.dr_save_order[0].invoke_arn
      authorization_type   = "COGNITO_USER_POOLS"
      request_schema       = file("${path.module}/models/create-order.json")
    }

    GetOrderViaLambda = {
      path_part            = "orders-via-lambda"
      child_path_part      = "{orderId}"
      http_method          = "GET"
      lambda_function_name = module.dr_get_order[0].function_name
      lambda_invoke_arn    = module.dr_get_order[0].invoke_arn
      authorization_type   = "COGNITO_USER_POOLS"
    }
  }

  dynamodb_routes = {
    GetOrder = {
      parent_path_part     = "orders"
      path_part            = "{orderId}"
      http_method          = "GET"
      authorization_type   = "COGNITO_USER_POOLS"
      action               = "Query"
      credentials_role_arn = module.dr_read_role[0].role_arn
      path_parameters      = ["orderId"]
      request_template     = replace(file("${path.module}/templates/get-order.request.vtl"), "__TABLE_NAME__", module.orders_table.table_name)
      response_template    = file("${path.module}/templates/get-order.response.vtl")
    }
  }
}

# The health route is added to the primary API too, so both regions are checked the same way.
# (Enabled on module.orders_api through enable_health_route.)

module "dr_api_waf" {
  count     = local.dr_enabled && var.enable_waf ? 1 : 0
  source    = "../../modules/waf-rate-limit"
  providers = { aws = aws.dr }

  name         = "orders-api-waf"
  resource_arn = module.dr_api[0].stage_arn
  rate_limit   = var.waf_rate_limit
}

module "primary_domain" {
  count  = local.dr_enabled ? 1 : 0
  source = "../../modules/api-custom-domain"

  domain_name = var.multi_region_domain
  zone_id     = data.aws_route53_zone.this[0].zone_id
  rest_api_id = module.orders_api.rest_api_id
  stage_name  = module.orders_api.stage_name

  depends_on = [terraform_data.multi_region_check]
}

module "dr_domain" {
  count     = local.dr_enabled ? 1 : 0
  source    = "../../modules/api-custom-domain"
  providers = { aws = aws.dr }

  domain_name = var.multi_region_domain
  zone_id     = data.aws_route53_zone.this[0].zone_id
  rest_api_id = module.dr_api[0].rest_api_id
  stage_name  = module.dr_api[0].stage_name

  # Same validation record as the primary certificate; apply them one after the other, not at the same moment.
  depends_on = [module.primary_domain]
}

module "multi_region_dns" {
  count  = local.dr_enabled ? 1 : 0
  source = "../../modules/route53-multi-region"

  zone_id     = data.aws_route53_zone.this[0].zone_id
  domain_name = var.multi_region_domain

  endpoints = {
    (var.aws_region) = {
      target_name    = module.primary_domain[0].regional_domain_name
      target_zone_id = module.primary_domain[0].regional_zone_id
      health_host    = module.orders_api.health_host
      health_path    = module.orders_api.health_path
    }
    (var.dr_region) = {
      target_name    = module.dr_domain[0].regional_domain_name
      target_zone_id = module.dr_domain[0].regional_zone_id
      health_host    = module.dr_api[0].health_host
      health_path    = module.dr_api[0].health_path
    }
  }
}
