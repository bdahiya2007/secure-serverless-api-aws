variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used for tagging."
  type        = string
  default     = "secure-serverless-api-aws"
}

variable "environment" {
  description = "Environment name, used for tagging."
  type        = string
  default     = "dev"
}

variable "enable_dax" {
  description = "Create a DynamoDB Accelerator (DAX) cluster in the default VPC and make the read Lambda (save-order-lookup) read through it. COSTS about $0.04 per node-hour for the cluster plus about $0.01 per hour for a CloudWatch Logs endpoint, with no free tier (about $0.05 per hour while on). Reads become eventually consistent and can be stale for up to dax_query_ttl_seconds after a write. Run ./scripts/build-dax-package.sh first, then terraform apply -var enable_dax=true; re-apply without it to remove."
  type        = bool
  default     = false
}

variable "dax_node_type" {
  description = "DAX node type used when enable_dax is true."
  type        = string
  default     = "dax.t3.small"
}

variable "dax_query_ttl_seconds" {
  description = "How long DAX serves a cached Query result (the maximum staleness of a read) when enable_dax is true."
  type        = number
  default     = 60
}

variable "enable_api_cache" {
  description = "Provision an API Gateway stage cache (0.5 GB) and cache GET responses for api_cache_ttl_seconds. COSTS by the hour even when idle (not free-tier eligible), and reads can be stale for up to the TTL after a write. Keep false unless demonstrating; apply with -var enable_api_cache=true, and re-apply without it to remove."
  type        = bool
  default     = false
}

variable "api_cache_ttl_seconds" {
  description = "Cache TTL used when enable_api_cache is true."
  type        = number
  default     = 300
}

variable "enable_waf" {
  description = "Attach an AWS WAF per-IP rate limit to the API. COSTS about $6/month (web ACL $5 + rule $1, billed hourly even when idle, plus $0.60 per million requests). Keep false unless demonstrating; apply with -var enable_waf=true, and re-apply without it to remove."
  type        = bool
  default     = false
}

variable "waf_rate_limit" {
  description = "Requests allowed per IP per 5 minutes before WAF blocks. Minimum 10."
  type        = number
  default     = 100
}

variable "app_role_boundary_name" {
  description = "Name of the permissions boundary policy created by terraform/bootstrap."
  type        = string
  default     = "serverless-api-pipeline-app-role-boundary"
}

variable "enable_multi_region" {
  description = "Make Orders a DynamoDB global table with a replica in dr_region AND run a second copy of the API (Lambda, API Gateway) there behind Route 53 latency routing (multi-region active/active). COSTS: every write is billed again in the replica region, plus a second stack, two Route 53 health checks and a few cents per hour of requests; no free tier for the health checks. Needs multi_region_domain and route53_zone_name. Applied locally (the deploy role cannot manage the second region); re-apply without it to remove."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_multi_region || (var.multi_region_domain != null && var.route53_zone_name != null)
    error_message = "enable_multi_region needs multi_region_domain (for example api.example.com) and route53_zone_name (an existing hosted zone, for example example.com)."
  }
}

variable "dr_region" {
  description = "Second region for the replica and the second API stack (us-west-2 is far from us-east-1, a different failure domain)."
  type        = string
  default     = "us-west-2"
}

variable "multi_region_domain" {
  description = "Name clients use for the multi-region API, for example api.example.com. It must be inside route53_zone_name and have no existing A record. Pass it at apply time; it is not committed."
  type        = string
  default     = null
}

variable "route53_zone_name" {
  description = "Name of the EXISTING Route 53 public hosted zone that contains multi_region_domain. Only new records for multi_region_domain and certificate validation are added to it; existing records are never changed."
  type        = string
  default     = null
}

variable "enable_federated_signin" {
  description = "Turn on sign-in with Google (Cognito hosted pages, authorization code flow with PKCE) and a sign-in guard Lambda that only lets allowed_emails in. With enable_multi_region also on, a second user pool is created in dr_region and both APIs trust both pools. Free at this scale (Cognito Lite plan, 10,000 free monthly active users, Lambda free tier). Needs federated_domain_prefix, google_client_id, google_client_secret and allowed_emails at apply time; none of them is committed."
  type        = bool
  default     = false

  validation {
    condition = !var.enable_federated_signin || (
      var.federated_domain_prefix != null && var.google_client_id != null && var.google_client_secret != null && length(var.allowed_emails) > 0
    )
    error_message = "enable_federated_signin needs federated_domain_prefix, google_client_id, google_client_secret and at least one allowed_emails entry."
  }
}

variable "federated_domain_prefix" {
  description = "Prefix of the hosted sign-in domain (<prefix>.auth.<region>.amazoncognito.com); unique per region across AWS. Pass it at apply time."
  type        = string
  default     = null
}

variable "google_client_id" {
  description = "Client ID of the Google OAuth client (Google Cloud console, Web application). Not a secret."
  type        = string
  default     = null
}

variable "google_client_secret" {
  description = "Client secret of the Google OAuth client. A SECRET: set it as TF_VAR_google_client_secret in your shell; never commit it or paste it anywhere. It is stored in the Terraform state."
  type        = string
  default     = null
  sensitive   = true
}

variable "allowed_emails" {
  description = "Google addresses allowed to sign in (case-insensitive). Personal data: set it as TF_VAR_allowed_emails (a JSON list) at apply time; never commit it. It is stored in the state and shown to administrators as a Lambda environment variable."
  type        = list(string)
  default     = []
  sensitive   = true
}

variable "federated_callback_urls" {
  description = "URLs the hosted pages may redirect back to. The default is the local helper script (scripts/demo/google-signin.py)."
  type        = list(string)
  default     = ["http://localhost:8765/callback"]
}

variable "cors_allowed_origins" {
  description = "Origins of the browser front end that may call the API (CORS), for example [\"https://orders.example.com\", \"http://localhost:8765\"]. Empty (the default) leaves the API exactly as it was. The FIRST origin is also used for errors that API Gateway produces itself, so list the production origin first. Passed to both APIs and the Lambdas (as ALLOWED_ORIGINS). The pipeline reads the repository variable CORS_ALLOWED_ORIGINS; it is not committed."
  type        = list(string)
  default     = []
}
