# The front end: a private bucket behind CloudFront at its own name, with its own certificate. It only ADDS resources next to
# the existing static website; it never references or edits that site's distribution, web ACL, buckets, certificate or records.

data "aws_caller_identity" "current" {}

data "aws_route53_zone" "this" {
  name         = var.route53_zone_name
  private_zone = false
}

# What the dev stack exposes for the page (all public values): the API, the hosted sign-in and the allowed CORS origins.
data "terraform_remote_state" "dev" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = var.dev_state_key
    region = "us-east-1"
  }
}

locals {
  dev        = data.terraform_remote_state.dev.outputs
  signin     = try(local.dev.browser_signin, null)
  origin_url = "https://${var.domain_name}"

  # create_order_url looks like https://<id>.execute-api.<region>.amazonaws.com/<stage>/orders
  api_base   = regex("^(.*)/orders$", local.dev.create_order_url)[0]
  api_origin = regex("^(https://[^/]+)", local.dev.create_order_url)[0]

  # Public settings the page reads at start-up (config.json). No secrets.
  config = {
    apiBaseUrl  = local.api_base
    redirectUri = "${local.origin_url}/"
    cognito = {
      host     = try(local.signin.host, "")
      clientId = try(local.signin.client_id, "")
      scopes   = try(join(" ", local.signin.scopes), "openid email")
    }
  }
}

# Stops the plan early, with a clear message, if something this front end depends on is missing.
resource "terraform_data" "checks" {
  lifecycle {
    precondition {
      condition     = endswith(var.domain_name, ".${trimsuffix(var.route53_zone_name, ".")}") && !startswith(var.domain_name, "www.") && var.domain_name != var.route53_zone_name
      error_message = "domain_name must be a name inside route53_zone_name (for example orders.example.com in example.com), and not the zone itself or www."
    }

    precondition {
      condition     = local.signin != null
      error_message = "The dev stack has no browser sign-in yet (its browser_signin output is empty). Apply the hosted sign-in first: set COGNITO_DOMAIN_PREFIX and BROWSER_CALLBACK_URLS."
    }

    precondition {
      condition     = contains(try(local.dev.cors_allowed_origins, []), local.origin_url)
      error_message = "The API does not allow this front end's origin yet. Add it to the repository variable CORS_ALLOWED_ORIGINS and let the deploy apply it."
    }

    precondition {
      condition     = contains(try(local.signin.callback_urls, []), "${local.origin_url}/")
      error_message = "The browser sign-in client does not list this front end's address as a callback URL yet. Add \"https://<domain>/\" to the repository variable BROWSER_CALLBACK_URLS and let the deploy apply it."
    }
  }
}

module "site" {
  source = "../modules/static-site"

  name        = "orders-frontend"
  bucket_name = "orders-frontend-${data.aws_caller_identity.current.account_id}"
  domain_name = var.domain_name
  zone_id     = data.aws_route53_zone.this.zone_id
  price_class = var.price_class

  # The page may call itself, the API and the Cognito hosted domain, and nothing else.
  csp_connect_sources = [local.api_origin, "https://${try(local.signin.host, "unset.invalid")}"]
  config              = local.config

  enable_waf              = var.enable_waf
  waf_rate_limit          = var.waf_rate_limit
  request_alarm_threshold = var.request_alarm_threshold

  depends_on = [terraform_data.checks]
}
