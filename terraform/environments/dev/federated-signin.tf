# ---------------------------------------------------------------------------
# Optional sign-in with Google (federated), OFF by default. Cognito's hosted pages send the user to Google, then issue the
# pool's own ID token, which both APIs already validate. A guard Lambda lets only allowed_emails in (see src/signin-guard).
# Free at this scale. With enable_multi_region also on, a second pool runs in dr_region and both APIs trust both pools.
# ---------------------------------------------------------------------------

locals {
  federated_enabled    = var.enable_federated_signin
  federated_dr_enabled = var.enable_federated_signin && var.enable_multi_region
}

module "signin_guard" {
  count  = local.federated_enabled ? 1 : 0
  source = "../../modules/lambda-function"

  function_name = "save-order-signin-guard"
  description   = "Cognito trigger: lets only allow-listed Google accounts sign in"
  source_dir    = "${path.root}/../../../src/signin-guard"
  handler       = "index.handler"

  # Cognito gives triggers 5 seconds. Allowed emails are personal data and are not secrets, so an environment variable is used.
  timeout     = 5
  memory_size = 128

  environment_variables = { ALLOWED_EMAILS = join(",", var.allowed_emails) }

  enable_xray_tracing  = false
  permissions_boundary = local.app_role_boundary_arn
}

resource "aws_lambda_permission" "signin_guard" {
  count = local.federated_enabled ? 1 : 0

  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.signin_guard[0].function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = module.orders_user_pool.user_pool_arn
}

# ----- second region (only with multi-region): its own Lambda and user pool -----

module "dr_signin_guard" {
  count     = local.federated_dr_enabled ? 1 : 0
  source    = "../../modules/lambda-function"
  providers = { aws = aws.dr }

  function_name = "save-order-signin-guard-dr"
  description   = "Cognito trigger (second region): lets only allow-listed Google accounts sign in"
  source_dir    = "${path.root}/../../../src/signin-guard"
  handler       = "index.handler"

  timeout     = 5
  memory_size = 128

  environment_variables = { ALLOWED_EMAILS = join(",", var.allowed_emails) }

  enable_xray_tracing  = false
  permissions_boundary = local.app_role_boundary_arn
}

module "dr_user_pool" {
  count     = local.federated_dr_enabled ? 1 : 0
  source    = "../../modules/cognito-user-pool"
  providers = { aws = aws.dr }

  name = "orders-api-users-dr"
  tier = "LITE"

  allow_admin_create_user_only = true
  mfa_configuration            = "OPTIONAL"
  deletion_protection_enabled  = false # so that switching the feature off can remove it

  domain_prefix           = var.federated_domain_prefix
  google_client_id        = var.google_client_id
  google_client_secret    = var.google_client_secret
  federated_callback_urls = var.federated_callback_urls
  signin_guard_lambda_arn = module.dr_signin_guard[0].function_arn
}

resource "aws_lambda_permission" "dr_signin_guard" {
  count    = local.federated_dr_enabled ? 1 : 0
  provider = aws.dr

  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.dr_signin_guard[0].function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = module.dr_user_pool[0].user_pool_arn
}

locals {
  # Every pool the APIs accept tokens from: the primary pool, plus the second region's pool when it exists.
  api_user_pool_arns = concat(
    [module.orders_user_pool.user_pool_arn],
    local.federated_dr_enabled ? [module.dr_user_pool[0].user_pool_arn] : [],
  )
}
