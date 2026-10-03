# secure-serverless-api-aws

Terraform for a serverless API on AWS, built incrementally. Free-tier friendly: anything that
costs money is off by default and documented below.

## Layout

```
terraform/
├── modules/dynamodb-table/   # reusable, validated DynamoDB table module
├── modules/lambda-function/  # reusable Lambda + least-privilege IAM role + log group
├── modules/rest-api/         # reusable REST API: Lambda proxy routes, validation, throttling, Cognito authorizer
├── modules/cognito-user-pool/ # reusable Cognito user pool + public app client
└── environments/dev/         # root config: provider, tags, Orders table, save-order function, orders API
src/save-order/               # Node.js Lambda code and unit tests
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

Outputs: `orders_table_name`, `orders_table_arn` (use the ARN for least-privilege IAM later).

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
| Not enabled | Access logs (needs an account-wide CloudWatch role), WAF, caching, CORS, custom domain, X-Ray |

Cost: REST API requests are about $3.50 per million. There is no charge while idle.

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

Unit tests need no dependencies (Node 22+):

```bash
node --test src/save-order/
```

## Usage

```bash
cd terraform/environments/dev
terraform init
terraform plan
terraform apply   # creates real resources; Lambda and on-demand DynamoDB cost nothing while idle
```

To destroy, first set `deletion_protection_enabled = false` in `environments/dev/main.tf` and apply.

## State

Local state for now (`*.tfstate` is git-ignored; it can hold sensitive data). Planned: S3 backend
with encryption and versioning.

## Cost switches (off until approved)

- `enable_point_in_time_recovery` — continuous backups, billed per GB.
- Customer-managed KMS key — monthly fee per key (not implemented).
- Cognito PLUS tier, SMS MFA, SES email — billed; not configured.
- X-Ray tracing, dead-letter queue, CloudWatch alarms, VPC attachment (NAT gateway) — not enabled.
- AWS WAF (monthly fee for the web ACL and rule), API caching (hourly), access logs, custom domain — not enabled.
