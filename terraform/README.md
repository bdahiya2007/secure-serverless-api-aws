# Terraform reference

Technical reference and runbook for the infrastructure in this repository. For the project overview and
architecture, see the [root README](../README.md).

Free-tier friendly: anything that costs money is off by default and documented below.

> **Paths and commands in this file are relative to the repository root** unless a `cd` says otherwise.

## Layout

```
terraform/
├── bootstrap/                     # applied MANUALLY: state bucket, permissions boundary, CI deploy role
├── environments/dev/              # root config: provider, tags, Orders table, save-order function, orders API
└── modules/
    ├── dynamodb-table/            # reusable, validated DynamoDB table module
    ├── lambda-function/           # Lambda + least-privilege IAM role + log group (+ boundary, X-Ray)
    ├── rest-api/                  # REST API: Lambda proxy routes, validation, throttling, Cognito authorizer
    ├── cognito-user-pool/         # Cognito user pool + public app client
    ├── waf-rate-limit/            # optional WAF per-IP rate limit (billed; off by default)
    └── cloudwatch-dashboard/      # API Gateway Count/4XXError, Lambda Invocations/Errors
src/save-order/                    # Node.js Lambda code and unit tests
.github/workflows/                 # validate.yml (PRs, no AWS) and deploy.yml (push to main, OIDC + approval)
docs/permission-set-inline-policy.json   # extra IAM your SSO permission set needs
```

## Orders table

| Setting | Value |
|---|---|
| Name | `Orders` |
| Partition key | `orderId` (S) |
| Sort key | `itemId` (S) |
| Capacity | On-demand (`PAY_PER_REQUEST`) |
| Encryption at rest | On, AWS-owned key (free) |
| Deletion protection | On (free) |
| Point-in-time recovery | **Off** (billed per GB, no free tier) |

Outputs: `orders_table_name`, `orders_table_arn` (the Lambda policy is scoped to this ARN).

## save-order Lambda

Saves one order item (one row) to the Orders table.

| Setting | Value |
|---|---|
| Runtime | `nodejs24.x` (latest GA; Node.js 26 is still public preview) |
| Architecture / memory / timeout | `arm64` / 128 MB / 10 s |
| IAM permissions | `dynamodb:PutItem` on the Orders table ARN only, plus write to its own log group |
| Logs | Explicit log group, JSON format, 14-day retention |
| Config | `TABLE_NAME` environment variable (from the table module output) |
| AWS SDK | The SDK v3 included in the Lambda runtime (no bundled dependencies) |
| Tracing | X-Ray active tracing (`enable_xray_tracing`); see Observability |

The module rejects wildcard IAM actions (`*`, `service:*`) and the `*` resource at plan time.

**Input** (`orderId` and `itemId` required; no other fields are accepted). The function accepts either
the order object itself (direct invoke) or an API Gateway proxy event whose `body` is the order as JSON:

```json
{ "orderId": "o-1001", "itemId": "i-1", "quantity": 2, "price": 9.99 }
```

| Status | Meaning |
|---|---|
| 201 | Saved (`createdAt` is added by the function) |
| 400 | Validation failed |
| 409 | `orderId` + `itemId` already exists (never overwritten) |
| 500 | Unexpected error (generic message; details are not returned or logged) |

Test after apply:

```bash
aws lambda invoke --function-name save-order \
  --cli-binary-format raw-in-base64-out \
  --payload '{"orderId":"o-1001","itemId":"i-1","quantity":2,"price":9.99}' /dev/stdout
```

## orders API (`POST /orders`)

| Setting | Value |
|---|---|
| Type | API Gateway REST API, regional endpoint, stage `dev` |
| Integration | Lambda proxy integration to `save-order` (only this API/stage/method may invoke it) |
| Authorization | **Cognito user pool authorizer** (`COGNITO_USER_POOLS`): requests need a valid ID token in the `Authorization` header. The module rejects `NONE`; `AWS_IAM` is also supported. |
| Request validation | JSON Schema model (`terraform/environments/dev/models/create-order.json`) rejects bad bodies before the Lambda runs. The Lambda validates again (defense in depth); keep the two in sync. |
| Throttling | 5 requests/second, burst 10, stage-wide |
| Not enabled | Access logs (needs an account-wide CloudWatch role), caching, CORS, custom domain, X-Ray on the API stage. WAF is available but **off by default** (see below). |

Cost: REST API requests are about $3.50 per million. There is no charge while idle.

## Observability

**CloudWatch dashboard** `orders-api-dev` (URL in `terraform output dashboard_url`) shows four widgets:
API Gateway `Count` and `4XXError`, Lambda `Invocations` and `Errors`. These are AWS-published metrics, which
are free, and the first 3 custom dashboards per account are free (each extra one is $3/month). The dashboard
uses no logs queries or custom metrics, which would be billed.

**X-Ray active tracing** is enabled on the Lambda. Enabling it is free; traces count against the X-Ray free
tier (verify current limits on the pricing page; beyond it, traces are billed per million). The Lambda role
gets `xray:PutTraceSegments` and `xray:PutTelemetryRecords` on `*`: X-Ray write actions do not support
resource-level permissions, so this is the one deliberate wildcard, limited to those two write-only actions.
Set `enable_xray_tracing = false` in `environments/dev/main.tf` to turn it off.

Limits: tracing starts at the Lambda (API Gateway stage tracing is not enabled), and DynamoDB calls do not
appear as separate nodes because that needs the X-Ray SDK bundled into the function (an npm dependency).

## WAF rate limit (optional, billed, OFF by default)

A WAF web ACL with one rate-based rule blocks any IP that sends more than 100 requests in 5 minutes
(HTTP 403). It is evaluated before API Gateway, so blocked requests never reach the authorizer or Lambda.
API Gateway's own throttle (5 req/s, burst 10) is stage-wide; this rule is per IP.

**Cost:** $5.00 per web ACL + $1.00 per rule per month, **prorated hourly and billed even when idle**,
plus $0.60 per million requests. No free tier. One ACL with one rule is about $6 per month, or about
$0.008 per hour, which exceeds the $5 budget if left on. Only enable it to demonstrate.

```bash
cd terraform/environments/dev
terraform apply -var enable_waf=true     # create (billing starts)
terraform apply                           # remove: re-apply WITHOUT the variable
terraform output waf_enabled              # check it is false when you are done
```

Demonstrate the block (no credentials needed; WAF runs before the authorizer). Expect 401/429 at first,
then 403 once the limit is exceeded (WAF enforcement can lag by about a minute):

```bash
URL=$(terraform output -raw create_order_url)
for i in $(seq 1 250); do curl -s -o /dev/null -w "%{http_code}\n" -X POST "$URL" -d '{}'; done | sort | uniq -c
```

Not enabled (each costs extra): WAF logging, managed rule groups, Bot Control, CAPTCHA.

## Cognito user pool

| Setting | Value |
|---|---|
| Tier | `LITE`: 10,000 monthly active users free, permanently. `PLUS` is rejected (no free tier). |
| Sign-up | Admin-created users only (no self sign-up) |
| Sign-in | Email address; strong password policy (12+ characters, upper, lower, number, symbol) |
| MFA | Optional, app-based TOTP only (free). SMS MFA is billed and not configured. |
| App client | Public (no secret), `USER_PASSWORD_AUTH` for CLI testing; user-existence errors hidden; token revocation on |
| Tokens | ID and access tokens 60 min, refresh token 7 days |
| Deletion protection | On. Set `deletion_protection_enabled = false` and apply before `terraform destroy`. |

Terraform does not create users, so no password ever lands in state. Create a test user:

```bash
cd terraform/environments/dev
POOL=$(terraform output -raw user_pool_id)
CLIENT=$(terraform output -raw user_pool_client_id)
EMAIL=you@example.com

aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$EMAIL" \
  --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true \
  --message-action SUPPRESS

read -rsp "New password: " PW; echo
aws cognito-idp admin-set-user-password --user-pool-id "$POOL" --username "$EMAIL" \
  --password "$PW" --permanent
```

Sign in, then call the API with the **ID token**:

```bash
ID_TOKEN=$(aws cognito-idp initiate-auth --client-id "$CLIENT" \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters USERNAME="$EMAIL",PASSWORD="$PW" \
  --query AuthenticationResult.IdToken --output text)

curl -sS -X POST "$(terraform output -raw create_order_url)" \
  -H "Authorization: $ID_TOKEN" -H "Content-Type: application/json" \
  -d '{"orderId":"o-1001","itemId":"i-1","quantity":2,"price":9.99}'
```

Without a valid token the API returns `401 Unauthorized`. Remove the test user when done:

```bash
aws cognito-idp admin-delete-user --user-pool-id "$POOL" --username "$EMAIL"
```

## Tests

The Lambda logic has 15 unit tests using Node's built-in runner (no dependencies, Node 22+). The AWS call is
injected, so no AWS access is needed. CI runs them on every pull request.

```bash
node --test src/save-order/
```

## AWS account prerequisites (your SSO permission set)

`PowerUserAccess` cannot manage IAM, but Terraform must create the Lambda execution role and, once, the
bootstrap resources. Add [docs/permission-set-inline-policy.json](../docs/permission-set-inline-policy.json) as an
inline policy on the permission set (IAM Identity Center -> Permission sets -> PowerUserAccess -> Inline
policy), reprovision the account, and run `aws sso login` again. The file uses `ACCOUNT_ID` as a placeholder so
the account ID is not published; print a ready-to-paste copy with:

```bash
sed "s/ACCOUNT_ID/$(aws sts get-caller-identity --query Account --output text)/" docs/permission-set-inline-policy.json
```

 It only allows IAM on `save-order-*` and
`serverless-api-pipeline-*` roles and the pipeline boundary policy.

## CI/CD (GitHub Actions)

| Workflow | Trigger | AWS access | What it does |
|---|---|---|---|
| `validate.yml` | Pull request to `main` | **None** | `terraform fmt -check`, `validate` (dev + bootstrap), Lambda unit tests, rejects committed state/tfvars. Required status check: **Validate Terraform and Lambda tests**. |
| `deploy.yml` | Push to `main` (changes under `terraform/environments`, `terraform/modules`, `src`) or manual run | OIDC role | **plan**, then **apply behind the `production` environment (manual approval)** of exactly that saved plan. |

- **No stored AWS keys.** The workflow assumes `AWS_DEPLOY_ROLE_ARN` through GitHub OIDC (short-lived tokens).
  Two repository secrets are needed: `AWS_DEPLOY_ROLE_ARN` and `TF_STATE_BUCKET` (the bucket name contains the
  AWS account ID, so it is passed with `-backend-config` and never committed).
- **The job summary is redacted.** The plan job lists only the action and resource address of each change, never
  ARNs or IDs, because the repository is public. The full plan is in the step log, where the AWS account ID is masked.
  The role's trust policy checks this repo by immutable owner/repo ID and allows only the `main` branch (plan)
  and the `production` environment (apply). Pull requests cannot assume it.
- **Packaging is Terraform.** `archive_file` zips `src/save-order`; `apply` updates the Lambda when the code hash
  changes. There is no separate `update-function-code` step.
- **The pipeline cannot change its own permissions.** The deploy role, state bucket and permissions boundary live
  in `terraform/bootstrap`, applied manually. The role can only create IAM roles that carry the boundary
  (a ceiling: logs, X-Ray writes, data access to the Orders table), and explicit Denies protect itself and the boundary.
- **Account-wide S3 Block Public Access** is enabled by the bootstrap (free;
  `block_public_access_account_wide`). Every existing bucket was audited first: all already block public
  access and are read only through CloudFront. If you ever need a public bucket, set the variable to
  `false` and apply the bootstrap.
- **State** is in a private, versioned, TLS-only, SSE-S3 encrypted S3 bucket with native locking
  (`use_lockfile`), old versions expire after 90 days. No DynamoDB lock table. Cost: pennies.
- **WAF caveat.** `deploy.yml` applies with `enable_waf=false` unless you run it manually with the input ticked.
  A push to `main` therefore **removes** a WAF you enabled by hand. Enable it via the workflow dispatch input.
- **First CI runs may report `AccessDenied`.** The deploy role's policy is resource-scoped and was written
  without being able to test it from CI. Add the missing action in `terraform/bootstrap/main.tf` and apply it manually.
- Actions are **pinned by commit SHA** (the repo requires it). Update the SHA and the version comment together.

### One-time setup, in order

```bash
# 1. Add docs/permission-set-inline-policy.json to your permission set, then: aws sso login

# 2. Bootstrap (local state; creates the state bucket, boundary policy and deploy role)
cd terraform/bootstrap
terraform init && terraform plan
terraform apply

# 3. Move the dev state into the bucket, then attach the boundary to the Lambda role
#    (the bucket name is not committed; it is read from the bootstrap output)
cd ../environments/dev
terraform init -migrate-state \
  -backend-config="bucket=$(terraform -chdir=../../bootstrap output -raw state_bucket)"   # answer "yes"
terraform plan                           # expect: save-order-role updated in place (boundary)
terraform apply

# 4. Give GitHub the role ARN and the state bucket name (both kept as secrets)
gh secret set AWS_DEPLOY_ROLE_ARN -R bdahiya2007/secure-serverless-api-aws \
  --body "$(terraform -chdir=../../bootstrap output -raw deploy_role_arn)"
gh secret set TF_STATE_BUCKET -R bdahiya2007/secure-serverless-api-aws \
  --body "$(terraform -chdir=../../bootstrap output -raw state_bucket)"
```

After the PR that adds `validate.yml` is merged, add its job name as a required status check on `main`:

```bash
gh api -X PATCH repos/bdahiya2007/secure-serverless-api-aws/branches/main/protection/required_status_checks \
  -f strict=true -f 'contexts[]=Validate Terraform and Lambda tests'
```

Repository settings mirror the three-tier repo: public, secret scanning and push protection on, `main`
protected (PR required, admins included, no force-push or deletion), `production` environment with a required
reviewer. Differences: Actions SHA pinning is required, and workflows cannot approve pull requests.

## Usage

```bash
cd terraform/environments/dev
terraform init -backend-config="bucket=$(terraform -chdir=../../bootstrap output -raw state_bucket)"
terraform plan
terraform apply   # creates real resources; Lambda and on-demand DynamoDB cost nothing while idle
# State is remote (S3): complete the one-time CI/CD setup above before the first init on a new machine.
# After pulling the commit that made the bucket name a -backend-config value, re-run init with -reconfigure.
```

To destroy, first set `deletion_protection_enabled = false` in `environments/dev/main.tf` and apply.

## State

Remote state in the S3 bucket created by `terraform/bootstrap` (key `dev/terraform.tfstate`; the bucket name is
supplied with `-backend-config` and not committed, since it contains the AWS account ID): private, versioned,
SSE-S3 encrypted, TLS-only, native locking. `terraform/bootstrap` itself uses local state (it creates the bucket),
which is git-ignored; keep that file safe. `*.tfstate` and `*.tfvars` are never committed.

## Cost switches (off until approved)

- `enable_point_in_time_recovery` — continuous backups, billed per GB.
- `enable_waf` — about $6/month while attached; off by default.
- Customer-managed KMS key — monthly fee per key (not implemented).
- Cognito PLUS tier, SMS MFA, SES email — billed; not configured.
- Extra CloudWatch dashboards (beyond 3 free), logs-insights widgets, custom metrics — billed; not used.
- API caching (hourly), API access logs, custom domain, WAF logging and managed rule groups — not enabled.
- Dead-letter queue, CloudWatch alarms, VPC attachment (needs a NAT gateway) — not enabled.
