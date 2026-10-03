locals {
  path_parts    = toset([for r in values(var.routes) : r.path_part])
  validated     = { for k, r in var.routes : k => r if r.request_schema != null }
  has_validated = length(local.validated) > 0
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

resource "aws_api_gateway_method" "this" {
  for_each = var.routes

  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.this[each.value.path_part].id
  http_method   = each.value.http_method
  authorization = each.value.authorization_type

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

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  # Redeploy whenever the route definitions change. Hashing the module inputs (known at
  # plan time) instead of whole resource objects avoids a spurious redeploy after the
  # first apply, when provider-filled defaults change the objects.
  triggers = {
    redeployment = sha1(jsonencode(var.routes))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_api_gateway_integration.this]
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
