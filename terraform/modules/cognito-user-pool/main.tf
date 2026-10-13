data "aws_region" "current" {}

resource "aws_cognito_user_pool" "this" {
  name = var.name

  user_pool_tier      = var.tier
  deletion_protection = var.deletion_protection_enabled ? "ACTIVE" : "INACTIVE"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  mfa_configuration = var.mfa_configuration

  # App-based TOTP only: free. SMS MFA would be billed through SNS and needs an IAM role.
  software_token_mfa_configuration {
    enabled = true
  }

  password_policy {
    minimum_length                   = var.password_minimum_length
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  admin_create_user_config {
    allow_admin_create_user_only = var.allow_admin_create_user_only
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Optional sign-in guard (a Lambda that allow-lists federated users). Pre sign-up stops a profile being created for a
  # stranger; pre token generation runs on every sign-in and refresh, so removing someone from the list locks them out.
  # V1_0 customises only the ID token, which every plan including Lite supports.
  dynamic "lambda_config" {
    for_each = var.signin_guard_lambda_arn == null ? [] : [1]

    content {
      pre_sign_up = var.signin_guard_lambda_arn

      pre_token_generation_config {
        lambda_arn     = var.signin_guard_lambda_arn
        lambda_version = "V1_0"
      }
    }
  }

  tags = var.tags
}

# Public client (no secret): suitable for CLIs and browser apps, which cannot keep a secret.
resource "aws_cognito_user_pool_client" "this" {
  name         = "${var.name}-client"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = false

  explicit_auth_flows = var.explicit_auth_flows

  # Do not reveal whether an email address has an account.
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  access_token_validity  = var.access_token_validity_minutes
  id_token_validity      = var.id_token_validity_minutes
  refresh_token_validity = var.refresh_token_validity_days

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }
}

# ---------------------------------------------------------------------------
# Optional hosted sign-in (Cognito's classic hosted UI, included in the Lite plan and free). Off unless a domain prefix is given.
#   * hosted UI:  a domain (<prefix>.auth.<region>.amazoncognito.com) with Cognito's own sign-in pages.
#   * browser client: a public client for a front end (authorization code flow with PKCE) with username and password on those
#     pages, when browser_callback_urls is given. Users are still created by an administrator (no self sign-up).
#   * Google: an optional identity provider and a separate Google-only client (needs the sign-in guard); off unless a Google
#     client ID is given. The password client above is untouched by all of this.
# ---------------------------------------------------------------------------

locals {
  hosted_ui = var.domain_prefix != null
  google    = var.google_client_id != null
  browser   = local.hosted_ui && length(var.browser_callback_urls) > 0
}

resource "terraform_data" "hosted_ui_check" {
  count = length(var.browser_callback_urls) > 0 || local.google ? 1 : 0

  lifecycle {
    precondition {
      condition     = local.hosted_ui
      error_message = "browser_callback_urls and Google sign-in both need the hosted UI: set domain_prefix."
    }
  }
}

resource "terraform_data" "federated_check" {
  count = local.google ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.google_client_secret != null
      error_message = "Google sign-in (google_client_id) needs google_client_secret."
    }

    precondition {
      condition     = var.signin_guard_lambda_arn != null
      error_message = "Google sign-in needs the sign-in guard (signin_guard_lambda_arn). Without it any Google account could sign in."
    }
  }
}

resource "aws_cognito_user_pool_domain" "this" {
  count = local.hosted_ui ? 1 : 0

  domain       = var.domain_prefix
  user_pool_id = aws_cognito_user_pool.this.id
}

# Public client for a browser front end: authorization code flow with PKCE (no secret, no implicit flow), signing in with a
# username and password on the hosted pages. The ID token it yields is the one the API's authorizer already validates.
resource "aws_cognito_user_pool_client" "browser" {
  count = local.browser ? 1 : 0

  name         = "${var.name}-browser-client"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = false

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls                        = var.browser_callback_urls
  logout_urls                          = var.browser_callback_urls

  explicit_auth_flows = ["ALLOW_REFRESH_TOKEN_AUTH"]

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  access_token_validity  = var.access_token_validity_minutes
  id_token_validity      = var.id_token_validity_minutes
  refresh_token_validity = var.refresh_token_validity_days

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  depends_on = [aws_cognito_user_pool_domain.this]
}

resource "aws_cognito_identity_provider" "google" {
  count = local.google ? 1 : 0

  user_pool_id  = aws_cognito_user_pool.this.id
  provider_name = "Google"
  provider_type = "Google"

  provider_details = {
    client_id        = var.google_client_id
    client_secret    = var.google_client_secret
    authorize_scopes = "openid email profile"
  }

  attribute_mapping = {
    email          = "email"
    email_verified = "email_verified"
    name           = "name"
    username       = "sub"
  }

  depends_on = [aws_cognito_user_pool_domain.this]
}

# A separate public app client for Google sign-in (authorization code flow with PKCE). It offers Google only: no password
# sign-in through the hosted pages, and no implicit flow.
resource "aws_cognito_user_pool_client" "federated" {
  count = local.google ? 1 : 0

  name         = "${var.name}-federated-client"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = false

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["Google"]
  callback_urls                        = var.federated_callback_urls
  logout_urls                          = var.federated_callback_urls

  explicit_auth_flows = ["ALLOW_REFRESH_TOKEN_AUTH"]

  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  access_token_validity  = var.access_token_validity_minutes
  id_token_validity      = var.id_token_validity_minutes
  refresh_token_validity = var.refresh_token_validity_days

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  depends_on = [aws_cognito_identity_provider.google]
}
