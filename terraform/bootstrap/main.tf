data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = var.aws_region

  # The GitHub OIDC provider already exists in this account (created for the three-tier
  # pipeline). A second provider for the same URL cannot be created, so reference it by ARN.
  oidc_provider_arn = "arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"

  # Immutable-ID subject prefix, as emitted by this repo's OIDC settings.
  sub_prefix = "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repository}@${var.github_repository_id}"

  deploy_role_name  = "${var.name_prefix}-deploy-role"
  deploy_role_arn   = "arn:aws:iam::${local.account_id}:role/${local.deploy_role_name}"
  boundary_name     = "${var.name_prefix}-app-role-boundary"
  boundary_arn      = "arn:aws:iam::${local.account_id}:policy/${local.boundary_name}"
  app_role_arn_glob = "arn:aws:iam::${local.account_id}:role/${var.app_role_prefix}-*"
  state_bucket_name = "secure-serverless-api-tfstate-${local.account_id}"

  table_arn    = "arn:aws:dynamodb:${local.region}:${local.account_id}:table/${var.orders_table_name}"
  function_arn = "arn:aws:lambda:${local.region}:${local.account_id}:function:${var.lambda_function_name}"
  log_group    = "arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/${var.lambda_function_name}"
}

# ---------------------------------------------------------------------------
# Terraform state bucket: private, versioned, encrypted, TLS-only, native locking
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 (AES-256): free. A customer-managed KMS key would add a monthly fee.
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    bucket_key_enabled = true

    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.state_noncurrent_version_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

data "aws_iam_policy_document" "state_bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = data.aws_iam_policy_document.state_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.state]
}

# ---------------------------------------------------------------------------
# Permissions boundary: the ceiling for every application role the pipeline creates.
# Even an admin-level inline policy on such a role yields no more than this.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "boundary" {
  statement {
    sid       = "LambdaLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${local.region}:${local.account_id}:log-group:/aws/lambda/*"]
  }

  # X-Ray write actions do not support resource-level permissions.
  statement {
    sid       = "XRayWrite"
    actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
    resources = ["*"]
  }

  statement {
    sid = "OrdersTableData"
    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:Query",
      "dynamodb:BatchGetItem",
      "dynamodb:BatchWriteItem",
      "dynamodb:ConditionCheckItem",
    ]
    resources = [local.table_arn, "${local.table_arn}/index/*"]
  }
}

resource "aws_iam_policy" "boundary" {
  name        = local.boundary_name
  description = "Permissions boundary for roles created by the serverless API pipeline"
  policy      = data.aws_iam_policy_document.boundary.json
}

# ---------------------------------------------------------------------------
# GitHub Actions deploy role (assumed through the existing OIDC provider)
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "deploy_trust" {
  statement {
    sid     = "GitHubOidc"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Plan jobs run on the branch; apply jobs run in the environment, whose sub claim differs.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${local.sub_prefix}:ref:refs/heads/${var.github_branch}",
        "${local.sub_prefix}:environment:${var.github_environment}",
      ]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name                 = local.deploy_role_name
  description          = "Assumed by GitHub Actions to deploy the serverless API (Terraform)"
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/${var.state_key_prefix}*"]
  }

  statement {
    sid       = "OrdersTable"
    actions   = ["dynamodb:*"]
    resources = [local.table_arn, "${local.table_arn}/*"]
  }

  statement {
    sid       = "SaveOrderFunction"
    actions   = ["lambda:*"]
    resources = [local.function_arn, "${local.function_arn}:*"]
  }

  statement {
    sid       = "FunctionLogGroup"
    actions   = ["logs:*"]
    resources = [local.log_group, "${local.log_group}:*"]
  }

  statement {
    sid       = "LogGroupDiscovery"
    actions   = ["logs:DescribeLogGroups", "logs:ListTagsForResource"]
    resources = ["*"]
  }

  statement {
    sid     = "ApiGateway"
    actions = ["apigateway:*"]
    resources = [
      "arn:aws:apigateway:${local.region}::/restapis",
      "arn:aws:apigateway:${local.region}::/restapis/*",
      "arn:aws:apigateway:${local.region}::/tags/*",
    ]
  }

  statement {
    sid       = "CognitoCreatePool"
    actions   = ["cognito-idp:CreateUserPool"]
    resources = ["*"]
  }

  statement {
    sid       = "CognitoManagePools"
    actions   = ["cognito-idp:*"]
    resources = ["arn:aws:cognito-idp:${local.region}:${local.account_id}:userpool/*"]
  }

  statement {
    sid       = "WafWebAcl"
    actions   = ["wafv2:*"]
    resources = ["arn:aws:wafv2:${local.region}:${local.account_id}:regional/webacl/orders-api-waf/*"]
  }

  statement {
    sid       = "WafDiscovery"
    actions   = ["wafv2:ListWebACLs", "wafv2:ListTagsForResource", "wafv2:GetWebACLForResource"]
    resources = ["*"]
  }

  statement {
    sid       = "Dashboards"
    actions   = ["cloudwatch:PutDashboard", "cloudwatch:GetDashboard", "cloudwatch:DeleteDashboards"]
    resources = ["arn:aws:cloudwatch::${local.account_id}:dashboard/orders-api-*"]
  }

  statement {
    sid       = "DashboardList"
    actions   = ["cloudwatch:ListDashboards"]
    resources = ["*"]
  }

  # Non-escalating IAM on application roles: read, tag, delete, pass to Lambda.
  statement {
    sid = "AppRoleLifecycle"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListInstanceProfilesForRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
    ]
    resources = [local.app_role_arn_glob]
  }

  statement {
    sid       = "PassAppRolesToLambda"
    actions   = ["iam:PassRole"]
    resources = [local.app_role_arn_glob]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }

  # Anything that grants permissions only works on a role carrying the boundary.
  statement {
    sid = "IamGrantsOnlyWithinBoundary"
    actions = [
      "iam:CreateRole",
      "iam:PutRolePolicy",
      "iam:AttachRolePolicy",
      "iam:PutRolePermissionsBoundary",
    ]
    resources = [local.app_role_arn_glob]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.boundary_arn]
    }
  }

  # Explicit denies win over every allow above.
  statement {
    sid       = "DenyPipelineSelfModification"
    effect    = "Deny"
    actions   = ["iam:*"]
    resources = [local.deploy_role_arn, local.boundary_arn]
  }

  statement {
    sid       = "DenyBoundaryRemoval"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "DeployServerlessApi"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
