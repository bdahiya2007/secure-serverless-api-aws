data "aws_region" "current" {}

locals {
  path_parts    = toset([for r in values(var.routes) : r.path_part])
  validated     = { for k, r in var.routes : k => r if r.request_schema != null }
  has_validated = length(local.validated) > 0

  # The resource each Lambda route attaches to: its child segment if it has one, else its root path part.
  route_resource_ids = merge(
    { for k, r in var.routes : k => aws_api_gateway_resource.this[r.path_part].id },
    { for k, r in aws_api_gateway_resource.child : k => r.id },
  )

  # Path parameters of a Lambda route's child segment, e.g. ["orderId"] for {orderId}. They must be declared on the
  # method and used as cache keys, or a cached response for one id could be served for another.
  route_path_parameters = {
    for k, r in var.routes : k => r.child_path_part == null ? [] : flatten(regexall("\\{([^}]+)\\}", r.child_path_part))
  }

  # Path used in the Lambda invoke permission: path parameters become wildcards in an execute-api ARN.
  route_arn_paths = {
    for k, r in var.routes : k => r.child_path_part == null ? r.path_part : "${r.path_part}/${replace(r.child_path_part, "/\\{[^}]+\\}/", "*")}"
  }

  # CORS (browser front end). Off unless origins are given. A response template for the non-proxy (direct DynamoDB) route and
  # the OPTIONS preflight sets Access-Control-Allow-Origin to the request's Origin only when that exact origin is listed.
  cors_enabled     = length(var.cors_allowed_origins) > 0
  cors_origin_list = "[${join(",", [for o in var.cors_allowed_origins : jsonencode(o)])}]"
  cors_vtl_origin  = <<-EOT
    #set($corsOrigin = $input.params('Origin'))
    #set($corsAllowed = ${local.cors_origin_list})
    #if($corsAllowed.contains($corsOrigin))
    #set($context.responseOverride.header.Access-Control-Allow-Origin = $corsOrigin)
    #end
    #set($context.responseOverride.header.Vary = "Origin")
  EOT
  # Prepended to the direct-route response templates; empty when CORS is off, so those templates are unchanged.
  cors_vtl_prefix = local.cors_enabled ? local.cors_vtl_origin : ""

  # Every resource that has a method needs an OPTIONS method for the preflight, listing that resource's real method.
  cors_targets = local.cors_enabled ? merge(
    { for k, r in var.routes : "route-${k}" => { resource_id = local.route_resource_ids[k], method = r.http_method } },
    { for k, r in var.dynamodb_routes : "ddb-${k}" => { resource_id = aws_api_gateway_resource.dynamodb[k].id, method = r.http_method } },
  ) : {}

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

# Optional child segment under a route's path part, for example the {orderId} in /orders-via-lambda/{orderId}.
resource "aws_api_gateway_resource" "child" {
  for_each = { for k, r in var.routes : k => r if r.child_path_part != null }

  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.this[each.value.path_part].id
  path_part   = each.value.child_path_part
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
  resource_id   = local.route_resource_ids[each.key]
  http_method   = each.value.http_method
  authorization = each.value.authorization_type
  authorizer_id = each.value.authorization_type == "COGNITO_USER_POOLS" ? aws_api_gateway_authorizer.cognito[0].id : null

  request_validator_id = each.value.request_schema != null ? aws_api_gateway_request_validator.body[0].id : null
  request_models       = each.value.request_schema != null ? { "application/json" = aws_api_gateway_model.this[each.key].name } : {}
  request_parameters   = { for p in local.route_path_parameters[each.key] : "method.request.path.${p}" => true }
}

resource "aws_api_gateway_integration" "this" {
  for_each = var.routes

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = local.route_resource_ids[each.key]
  http_method = aws_api_gateway_method.this[each.key].http_method

  # Lambda proxy integration: API Gateway always invokes with POST.
  type                    = "AWS_PROXY"
  integration_http_method = "POST"
  uri                     = each.value.lambda_invoke_arn

  # Cache entries are keyed by the path parameters, so each id is cached separately.
  cache_key_parameters = [for p in local.route_path_parameters[each.key] : "method.request.path.${p}"]
  cache_namespace      = each.key
}

# Only this API, this stage, this method and this path may invoke the function.
resource "aws_lambda_permission" "this" {
  for_each = var.routes

  statement_id  = "AllowApiGatewayInvoke-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = each.value.lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/${var.stage_name}/${each.value.http_method}/${local.route_arn_paths[each.key]}"
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

  # Cache entries are keyed by the path parameters, so each id is cached separately.
  cache_key_parameters = [for p in each.value.path_parameters : "method.request.path.${p}"]
  cache_namespace      = each.key
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
    "application/json" = "${local.cors_vtl_prefix}${each.value.status == "200" ? var.dynamodb_routes[each.value.route].response_template : local.dynamodb_static_bodies[each.value.status]}"
  }

  depends_on = [aws_api_gateway_integration.dynamodb, aws_api_gateway_method_response.dynamodb]
}

# ---------------------------------------------------------------------------
# Optional health route for Route 53 health checks: GET /health answers 200 from API Gateway itself (a MOCK integration, so
# no Lambda or DynamoDB is called and nothing is billed beyond the request). It is deliberately unauthenticated, because a
# health checker has no token, and it proves only that this region's API Gateway is up, not that DynamoDB or Lambda work.
# ---------------------------------------------------------------------------

resource "aws_api_gateway_resource" "health" {
  count = var.enable_health_route ? 1 : 0

  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "health"
}

resource "aws_api_gateway_method" "health" {
  count = var.enable_health_route ? 1 : 0

  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.health[0].id
  http_method   = "GET"
  authorization = "NONE" # health checkers cannot send a token; the route returns a fixed body
}

resource "aws_api_gateway_integration" "health" {
  count = var.enable_health_route ? 1 : 0

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.health[0].id
  http_method = aws_api_gateway_method.health[0].http_method

  type              = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "health" {
  count = var.enable_health_route ? 1 : 0

  rest_api_id     = aws_api_gateway_rest_api.this.id
  resource_id     = aws_api_gateway_resource.health[0].id
  http_method     = aws_api_gateway_method.health[0].http_method
  status_code     = "200"
  response_models = { "application/json" = "Empty" }
}

resource "aws_api_gateway_integration_response" "health" {
  count = var.enable_health_route ? 1 : 0

  rest_api_id        = aws_api_gateway_rest_api.this.id
  resource_id        = aws_api_gateway_resource.health[0].id
  http_method        = aws_api_gateway_method.health[0].http_method
  status_code        = aws_api_gateway_method_response.health[0].status_code
  response_templates = { "application/json" = "{\"status\":\"ok\",\"region\":\"${data.aws_region.current.region}\"}" }

  depends_on = [aws_api_gateway_integration.health]
}

# ---------------------------------------------------------------------------
# Optional CORS for a browser front end. A browser sends an unauthenticated OPTIONS "preflight" before a cross-origin call that
# has an Authorization header, so each route's resource gets an OPTIONS method answered by API Gateway itself (a MOCK
# integration: no Lambda or DynamoDB call, nothing billed beyond the request). The method has no authorizer on purpose,
# because the browser sends no credentials in a preflight; it returns no data.
# ---------------------------------------------------------------------------

resource "aws_api_gateway_method" "cors" {
  for_each = local.cors_targets

  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = each.value.resource_id
  http_method   = "OPTIONS"
  authorization = "NONE" # a preflight carries no credentials; the response holds no data
}

resource "aws_api_gateway_integration" "cors" {
  for_each = local.cors_targets

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = each.value.resource_id
  http_method = aws_api_gateway_method.cors[each.key].http_method

  type              = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "cors" {
  for_each = local.cors_targets

  rest_api_id     = aws_api_gateway_rest_api.this.id
  resource_id     = each.value.resource_id
  http_method     = aws_api_gateway_method.cors[each.key].http_method
  status_code     = "200"
  response_models = { "application/json" = "Empty" }
}

# The allow headers are added only for a listed origin; Vary: Origin is always added so caches do not mix origins.
resource "aws_api_gateway_integration_response" "cors" {
  for_each = local.cors_targets

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = each.value.resource_id
  http_method = aws_api_gateway_method.cors[each.key].http_method
  status_code = aws_api_gateway_method_response.cors[each.key].status_code

  response_templates = {
    "application/json" = <<-EOT
      #set($corsOrigin = $input.params('Origin'))
      #set($corsAllowed = ${local.cors_origin_list})
      #if($corsAllowed.contains($corsOrigin))
      #set($context.responseOverride.header.Access-Control-Allow-Origin = $corsOrigin)
      #set($context.responseOverride.header.Access-Control-Allow-Methods = "${each.value.method},OPTIONS")
      #set($context.responseOverride.header.Access-Control-Allow-Headers = "Authorization,Content-Type")
      #set($context.responseOverride.header.Access-Control-Max-Age = "600")
      #end
      #set($context.responseOverride.header.Vary = "Origin")
    EOT
  }

  depends_on = [aws_api_gateway_integration.cors]
}

# Errors that API Gateway produces itself (401 from the authorizer, 403, 429, request validation 400, 5xx) never reach a Lambda
# or a template, so without this a browser sees an opaque network error instead of the status. A gateway response cannot choose
# the origin dynamically, so these carry the header for the FIRST listed origin only (put the production origin first).
resource "aws_api_gateway_gateway_response" "cors" {
  for_each = local.cors_enabled ? toset(["DEFAULT_4XX", "DEFAULT_5XX"]) : toset([])

  rest_api_id   = aws_api_gateway_rest_api.this.id
  response_type = each.value

  response_parameters = {
    "gatewayresponse.header.Access-Control-Allow-Origin"  = "'${var.cors_allowed_origins[0]}'"
    "gatewayresponse.header.Access-Control-Allow-Headers" = "'Authorization,Content-Type'"
    "gatewayresponse.header.Vary"                         = "'Origin'"
  }
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  # Redeploy whenever the routes or authorizer change. Hashing the module inputs (known at
  # plan time) instead of whole resource objects avoids a spurious redeploy after the
  # first apply, when provider-filled defaults change the objects.
  triggers = {
    redeployment = sha1(jsonencode(concat([var.routes, var.cognito_user_pool_arns, var.dynamodb_routes, var.cache_enabled, var.cache_size_gb, var.cache_ttl_seconds, "cache-keys-v1"], var.enable_health_route ? ["health-v1"] : [], local.cors_enabled ? [jsonencode(["cors-v1", var.cors_allowed_origins])] : [])))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.this,
    aws_api_gateway_integration.dynamodb,
    aws_api_gateway_integration_response.dynamodb,
    aws_api_gateway_integration_response.health,
    aws_api_gateway_integration_response.cors,
    aws_api_gateway_gateway_response.cors,
  ]
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = var.stage_name

  # Off by default. A stage cache is billed by the hour even when idle.
  cache_cluster_enabled = var.cache_enabled
  cache_cluster_size    = var.cache_enabled ? var.cache_size_gb : null

  tags = var.tags
}

# Default throttling for every method in the stage: each method gets its own token bucket with these limits, and all callers
# of a method share it (it is not per client). No logging or detailed metrics settings, so this needs no
# account-level CloudWatch role and adds no cost.
resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    throttling_rate_limit  = var.throttling_rate_limit
    throttling_burst_limit = var.throttling_burst_limit

    # Only GET methods are cached by API Gateway. Cached data is encrypted, and a client cannot bypass the cache or force
    # a backend call by sending Cache-Control: max-age=0 (the header is ignored), which would otherwise let anyone skip
    # the cache at the backend's expense.
    caching_enabled                            = var.cache_enabled
    cache_ttl_in_seconds                       = var.cache_ttl_seconds
    cache_data_encrypted                       = true
    unauthorized_cache_control_header_strategy = "SUCCEED_WITHOUT_RESPONSE_HEADER"
  }
}
