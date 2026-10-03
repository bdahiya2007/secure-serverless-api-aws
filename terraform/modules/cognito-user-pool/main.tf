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
