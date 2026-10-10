data "aws_region" "current" {}

locals {
  path_parts    = toset([for r in values(var.routes) : r.path_part])
  validated     = { for k, r in var.routes : k => r if r.request_schema != null }
  has_validated = length(local.validated) > 0

  # One method response per outcome. 404 is produced by the success template through
  # $context.responseOverride.status, so it has no integration response of its own.
  dynamodb_statuses              = ["200", "400", "404", "500"]
  dynamodb_responses             = { for pair in setproduct(keys(var.dynamodb_routes), local.dynamodb_statuses) : "${pair[0]}-${pair[1]}" => { route = pair[0], status = pair[1] } }
  dynamodb_integration_responses = { for k, v in local.dynamodb_responses : k => v if v.status != "404" }
  dynamodb_selection_patterns    = { "200" = null, "400" = "4\\d{2}", "500" = "5\\d{2}" }
  dynamodb_static_bodies         = { "400" = "{\"message\":\"Bad request\"}", "500" = "{\"message\":\"Internal error\"}" }
}

resource "aws_api_gateway_rest_api" "this" {
  name        = var.name
  description = var.description

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = var.tags
}

resource "aws_api_gateway_resource" "this" {
  for_each = local.path_parts

  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = each.value
}

# Rejects malformed bodies at the edge, before the Lambda is invoked or billed.
resource "aws_api_gateway_request_validator" "body" {
  count = local.has_validated ? 1 : 0

  name                        = "${var.name}-validate-body"
  rest_api_id                 = aws_api_gateway_rest_api.this.id
  validate_request_body       = true
  validate_request_parameters = false
}

resource "aws_api_gateway_model" "this" {
  for_each = local.validated

  rest_api_id  = aws_api_gateway_rest_api.this.id
  name         = each.key
  content_type = "application/json"
  schema       = each.value.request_schema
}

# Validates the Cognito ID token sent in the Authorization header. Rejected requests
# never reach the Lambda, so unauthenticated calls cost nothing beyond the API request.
resource "aws_api_gateway_authorizer" "cognito" {
  count = length(var.cognito_user_pool_arns) > 0 ? 1 : 0

  name            = "${var.name}-cognito"
  rest_api_id     = aws_api_gateway_rest_api.this.id
  type            = "COGNITO_USER_POOLS"
  provider_arns   = var.cognito_user_pool_arns
  identity_source = "method.request.header.Authorization"
}

resource "aws_api_gateway_method" "this" {
  for_each = var.routes

  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.this[each.value.path_part].id
  http_method   = each.value.http_method
  authorization = each.value.authorization_type
  authorizer_id = each.value.authorization_type == "COGNITO_USER_POOLS" ? aws_api_gateway_authorizer.cognito[0].id : null

  request_validator_id = each.value.request_schema != null ? aws_api_gateway_request_validator.body[0].id : null
  request_models       = each.value.request_schema != null ? { "application/json" = aws_api_gateway_model.this[each.key].name } : {}
}

resource "aws_api_gateway_integration" "this" {
  for_each = var.routes

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.this[each.value.path_part].id
  http_method = aws_api_gateway_method.this[each.key].http_method

  # Lambda proxy integration: API Gateway always invokes with POST.
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = each.value.lambda_invoke_arn
}

# Only this API, this stage, this method and this path may invoke the function.
resource "aws_lambda_permission" "this" {
  for_each = var.routes

  statement_id  = "AllowApiGatewayInvoke-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = each.value.lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/${var.stage_name}/${each.value.http_method}/${each.value.path_part}"
}

# ---------------------------------------------------------------------------
# Direct DynamoDB integrations: API Gateway calls DynamoDB itself, with no Lambda in the path.
# ---------------------------------------------------------------------------

resource "aws_api_gateway_resource" "dynamodb" {
  for_each = var.dynamodb_routes

  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.this[each.value.parent_path_part].id
  path_part   = each.value.path_part
}

resource "aws_api_gateway_method" "dynamodb" {
  for_each = var.dynamodb_routes

  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.dynamodb[each.key].id
  http_method   = each.value.http_method
  authorization = each.value.authorization_type
  authorizer_id = each.value.authorization_type == "COGNITO_USER_POOLS" ? aws_api_gateway_authorizer.cognito[0].id : null

  request_parameters = { for p in each.value.path_parameters : "method.request.path.${p}" => true }
}

resource "aws_api_gateway_integration" "dynamodb" {
  for_each = var.dynamodb_routes

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.dynamodb[each.key].id
  http_method = aws_api_gateway_method.dynamodb[each.key].http_method

  # DynamoDB's API is always called with POST, whatever the client method was.
  type                    = "AWS"
  integration_http_method = "POST"
  uri                     = "arn:aws:apigateway:${data.aws_region.current.region}:dynamodb:action/${each.value.action}"
  credentials             = each.value.credentials_role_arn

  # Only bodies that match a template are forwarded; anything else is rejected with 415.
  passthrough_behavior = "NEVER"
  request_templates    = { "application/json" = each.value.request_template }
  timeout_milliseconds = 5000
}

resource "aws_api_gateway_method_response" "dynamodb" {
  for_each = local.dynamodb_responses

  rest_api_id     = aws_api_gateway_rest_api.this.id
  resource_id     = aws_api_gateway_resource.dynamodb[each.value.route].id
  http_method     = aws_api_gateway_method.dynamodb[each.value.route].http_method
  status_code     = each.value.status
  response_models = { "application/json" = "Empty" }
}

# 200 uses the route's response template. 4xx and 5xx from DynamoDB get fixed generic bodies, so internal
# error details (table names, validation messages) never reach the client.
resource "aws_api_gateway_integration_response" "dynamodb" {
  for_each = local.dynamodb_integration_responses

  rest_api_id       = aws_api_gateway_rest_api.this.id
  resource_id       = aws_api_gateway_resource.dynamodb[each.value.route].id
  http_method       = aws_api_gateway_method.dynamodb[each.value.route].http_method
  status_code       = each.value.status
  selection_pattern = local.dynamodb_selection_patterns[each.value.status]

  response_templates = {
    "application/json" = each.value.status == "200" ? var.dynamodb_routes[each.value.route].response_template : local.dynamodb_static_bodies[each.value.status]
  }

  depends_on = [aws_api_gateway_integration.dynamodb, aws_api_gateway_method_response.dynamodb]
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  # Redeploy whenever the routes or authorizer change. Hashing the module inputs (known at
  # plan time) instead of whole resource objects avoids a spurious redeploy after the
  # first apply, when provider-filled defaults change the objects.
  triggers = {
    redeployment = sha1(jsonencode([var.routes, var.cognito_user_pool_arns, var.dynamodb_routes]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.this,
    aws_api_gateway_integration.dynamodb,
    aws_api_gateway_integration_response.dynamodb,
  ]
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = var.stage_name

  tags = var.tags
}

# Stage-wide throttling. No logging or detailed metrics settings, so this needs no
# account-level CloudWatch role and adds no cost.
resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    throttling_rate_limit  = var.throttling_rate_limit
    throttling_burst_limit = var.throttling_burst_limit
  }
}
