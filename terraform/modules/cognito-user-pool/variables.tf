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

variable "domain_prefix" {
  description = "Prefix of the hosted sign-in domain (<prefix>.auth.<region>.amazoncognito.com). Setting it turns on federated sign-in with Google and requires google_client_id and google_client_secret. Lower-case letters, numbers and hyphens; may not contain aws, amazon or cognito."
  type        = string
  default     = null

  validation {
    condition     = var.domain_prefix == null || (can(regex("^[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$", coalesce(var.domain_prefix, "aa"))) && !can(regex("aws|amazon|cognito", coalesce(var.domain_prefix, "x"))))
    error_message = "domain_prefix must be 2 to 63 lower-case letters, numbers or hyphens, start and end with a letter or number, and not contain aws, amazon or cognito."
  }
}

variable "google_client_id" {
  description = "Client ID of the Google OAuth client. Required with domain_prefix. Not a secret."
  type        = string
  default     = null
}

variable "google_client_secret" {
  description = "Client secret of the Google OAuth client. Required with domain_prefix. A SECRET: pass it at apply time (TF_VAR_google_client_secret), never commit it. It is stored in the Terraform state."
  type        = string
  default     = null
  sensitive   = true
}

variable "federated_callback_urls" {
  description = "URLs the hosted pages may redirect back to after sign-in (and sign-out). http is allowed for localhost only."
  type        = list(string)
  default     = ["http://localhost:8765/callback"]

  validation {
    condition     = alltrue([for u in var.federated_callback_urls : startswith(u, "https://") || startswith(u, "http://localhost")])
    error_message = "Callback URLs must use https, or http only for localhost."
  }
}

variable "signin_guard_lambda_arn" {
  description = "ARN of the sign-in guard Lambda (pre sign-up and pre token generation). Null means no guard. With federated sign-in on, a guard is required."
  type        = string
  default     = null
}
