# secure-serverless-api-aws

Terraform for a serverless API on AWS, built incrementally. Free-tier friendly: anything that
costs money is off by default and documented below.

## Layout

```
terraform/
├── modules/dynamodb-table/   # reusable, validated DynamoDB table module
├── modules/lambda-function/  # reusable Lambda + least-privilege IAM role + log group
├── modules/rest-api/         # reusable REST API: Lambda proxy routes, validation, throttling
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
| Authorization | **`AWS_IAM`**: requests must be SigV4-signed. The module rejects `NONE`. Cognito replaces this in a later step. |
| Request validation | JSON Schema model (`terraform/environments/dev/models/create-order.json`) rejects bad bodies before the Lambda runs. The Lambda validates again (defense in depth); keep the two in sync. |
| Throttling | 5 requests/second, burst 10, stage-wide |
| Not enabled | Access logs (needs an account-wide CloudWatch role), WAF, caching, CORS, custom domain, X-Ray |

Cost: REST API requests are about $3.50 per million. There is no charge while idle.

Call it after apply (SigV4 with your SSO credentials):

```bash
URL=$(terraform -chdir=terraform/environments/dev output -raw create_order_url)
eval "$(aws configure export-credentials --format env)"
curl -sS -X POST "$URL" \
  --aws-sigv4 "aws:amz:us-east-1:execute-api" \
  --user "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
  -H "x-amz-security-token: $AWS_SESSION_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"orderId":"o-1001","itemId":"i-1","quantity":2,"price":9.99}'
```

An unsigned request returns `403 Missing Authentication Token`.

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
- X-Ray tracing, dead-letter queue, CloudWatch alarms, VPC attachment (NAT gateway) — not enabled.
- AWS WAF (monthly fee for the web ACL and rule), API caching (hourly), access logs, custom domain — not enabled.
