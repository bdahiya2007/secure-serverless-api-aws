variable "name" {
  description = "Name of the user pool. The app client is named \"<name>-client\"."
  type        = string
}

variable "tier" {
  description = "Cognito pricing tier. LITE and ESSENTIALS include 10,000 monthly active users free; PLUS has no free tier and is rejected."
  type        = string
  default     = "LITE"

  validation {
    condition     = contains(["LITE", "ESSENTIALS"], var.tier)
    error_message = "tier must be LITE or ESSENTIALS. PLUS has no free tier and needs an explicit cost decision."
  }
}

variable "allow_admin_create_user_only" {
  description = "Disable self sign-up: only administrators can create users."
  type        = bool
  default     = true
}

variable "mfa_configuration" {
  description = "OFF, OPTIONAL or ON. Only app-based TOTP is enabled; SMS MFA is billed and is not configured."
  type        = string
  default     = "OPTIONAL"

  validation {
    condition     = contains(["OFF", "OPTIONAL", "ON"], var.mfa_configuration)
    error_message = "mfa_configuration must be OFF, OPTIONAL or ON."
  }
}

variable "password_minimum_length" {
  description = "Minimum password length."
  type        = number
  default     = 12

  validation {
    condition     = var.password_minimum_length >= 12 && var.password_minimum_length <= 99
    error_message = "password_minimum_length must be between 12 and 99."
  }
}

variable "deletion_protection_enabled" {
  description = "Block deletion of the user pool (free). Set to false before running terraform destroy."
  type        = bool
  default     = true
}

variable "explicit_auth_flows" {
  description = "Auth flows enabled on the app client. USER_PASSWORD_AUTH suits CLI testing; production browser apps should use the authorization code flow with PKCE."
  type        = list(string)
  default     = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
}

variable "access_token_validity_minutes" {
  description = "Lifetime of access tokens."
  type        = number
  default     = 60
}

variable "id_token_validity_minutes" {
  description = "Lifetime of ID tokens (the token API Gateway validates)."
  type        = number
  default     = 60
}

variable "refresh_token_validity_days" {
  description = "Lifetime of refresh tokens."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags applied to the user pool."
  type        = map(string)
  default     = {}
}
