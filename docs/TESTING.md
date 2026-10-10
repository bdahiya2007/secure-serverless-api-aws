# Testing guide

How to test the orders API, from fastest to most complete. Commands run from the repository root unless a
`cd` says otherwise.

| Level | Needs AWS | Time | What it proves |
|---|---|---|---|
| [1. Unit tests](#1-unit-tests) | No | seconds | The Lambda's validation and error handling |
| [2. Static checks](#2-static-checks) | No | seconds | Terraform formatting and validity |
| [3. End-to-end](#3-end-to-end-against-the-deployed-api) | Yes | about 1 minute | The whole chain: Cognito, API Gateway, Lambda, DynamoDB |
| [4. Observability](#4-check-observability) | Yes | minutes | Metrics, logs and traces are being produced |
| [5. Pipeline](#5-test-the-pipeline) | GitHub | minutes | CI validation and the approval-gated deploy |
| [6. WAF](#6-waf-rate-limit-optional-billed) | Yes | minutes | Per-IP rate limiting (**billed**) |

**Prerequisites:** an AWS session (`aws sso login`), `terraform`, `curl`, `openssl`, `python3`, and Node.js 22 or newer
for the unit tests. The API must already be deployed (see [terraform/README.md](../terraform/README.md)).

## 1. Unit tests

```bash
node --test "src/*/*.test.mjs"               # expect 23 passing (both Lambdas)
```

Pass the **glob in quotes**. `node --test src/save-order/` (a folder) fails because Node treats it as a module path. `src/*/*.test.mjs` covers both Lambdas (`save-order` and `get-order`).
The tests inject the DynamoDB call, so they need no AWS access. They cover validation, the duplicate check, API
Gateway proxy events (JSON and base64 bodies, malformed JSON) and the generic 500.

## 2. Static checks

```bash
terraform fmt -check -recursive terraform
cd terraform/environments/dev
terraform init -backend=false && terraform validate
```

CI runs both of these, plus the unit tests, on every pull request.

## 3. End-to-end against the deployed API

### Option A: the script (recommended)

```bash
./scripts/e2e-test.sh
```

It creates a temporary Cognito user, calls `POST /orders`, `GET /orders/{orderId}` (the direct DynamoDB integration) and `GET /orders-via-lambda/{orderId}` (the Lambda read) for sixteen cases, prints PASS or FAIL for each, and
**always deletes the user and the order rows afterwards** (an `EXIT` trap, so cleanup also runs if a check
fails). The exit code is non-zero if any case fails. Expected output:

```
  PASS  valid order is saved                                 HTTP 201
  PASS  same order again is rejected (no overwrite)          HTTP 409
  PASS  no token                                             HTTP 401
  PASS  access token instead of ID token                     HTTP 401
  PASS  missing orderId and an extra field                   HTTP 400
  PASS  malformed JSON                                       HTTP 400
  PASS  read the order back (200, item present)              HTTP 200
  PASS  read keeps numbers as numbers                        HTTP 200
  PASS  unknown order                                        HTTP 404
  PASS  id with a quote is handled safely                    HTTP 404
  PASS  read without a token                                 HTTP 401
  PASS  Lambda read: order with its items                    HTTP 200
  PASS  Lambda read: numbers, and truncated flag             HTTP 200
  PASS  Lambda read: unknown order                           HTTP 404
  PASS  Lambda read: invalid id is rejected                  HTTP 400
  PASS  Lambda read: no token                                HTTP 401

Result: 16 passed, 0 failed
Cleaning up...
  Orders rows left:  0
  Cognito users left: 0
```

### Option B: by hand

Useful for exploring or debugging a single case.

```bash
cd terraform/environments/dev
POOL=$(terraform output -raw user_pool_id)
CLIENT=$(terraform output -raw user_pool_client_id)
URL=$(terraform output -raw create_order_url)
EMAIL="test-$(openssl rand -hex 3)@example.com"

# 1. Create a temporary user (no email is sent) and set a password you type
aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$EMAIL" \
  --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true --message-action SUPPRESS
read -rsp "Password (12+ chars, upper, lower, number, symbol): " PW; echo
aws cognito-idp admin-set-user-password --user-pool-id "$POOL" --username "$EMAIL" --password "$PW" --permanent

# 2. Sign in. Use the ID token: the authorizer rejects the access token.
TOK=$(aws cognito-idp initiate-auth --client-id "$CLIENT" --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters USERNAME="$EMAIL",PASSWORD="$PW" --query AuthenticationResult.IdToken --output text)

# 3. Call the API
call() { curl -sS -w '  -> HTTP %{http_code}\n' -X POST "$URL" -H "Content-Type: application/json" "$@"; }
call -H "Authorization: $TOK" -d '{"orderId":"t-1","itemId":"i-1","quantity":2,"price":9.99}'
```

| Request | Expected |
|---|---|
| The call above | **201** `{"orderId":…,"itemId":…,"createdAt":…}` |
| The same call again | **409** `Order item already exists` (the first row is not overwritten) |
| Without the `Authorization` header: `call -d '{"orderId":"t-2","itemId":"i-1"}'` | **401** `Unauthorized` |
| Access token instead of the ID token | **401** |
| `call -H "Authorization: $TOK" -d '{"itemId":"i-1","extra":1}'` | **400** `Invalid request body`, rejected by API Gateway before the Lambda runs |
| `call -H "Authorization: $TOK" -d '{not json'` | **400** |

Read the order back. This request goes from API Gateway straight to DynamoDB; no Lambda runs:

```bash
curl -sS -H "Authorization: $TOK" "$URL/t-1"                       # 200 with the items
curl -sS -o /dev/null -w '%{http_code}\n' -H "Authorization: $TOK" "$URL/no-such-order"   # 404
curl -sS -o /dev/null -w '%{http_code}\n' "$URL/t-1"              # 401 (no token)
```

Expected body for a stored order (missing `quantity` or `price` appear as `null`):

```json
{ "orderId": "t-1", "itemCount": 1, "items": [ { "itemId": "i-1", "quantity": 2, "price": 9.99, "createdAt": "…" } ] }
```

The same read through a Lambda (`save-order-lookup`), for comparison:

```bash
curl -sS -H "Authorization: $TOK" "${URL%/orders}/orders-via-lambda/t-1"     # 200, compact JSON with a "truncated" flag
curl -sS -o /dev/null -w '%{http_code}\n' -H "Authorization: $TOK" "${URL%/orders}/orders-via-lambda/a%22b"   # 400 (the direct read returns 404)
```

Check the item was stored directly in the table:

```bash
aws dynamodb get-item --table-name Orders --key '{"orderId":{"S":"t-1"},"itemId":{"S":"i-1"}}'
```

**Clean up, always.** A leftover test user is a working login to the API.

```bash
aws dynamodb delete-item --table-name Orders --key '{"orderId":{"S":"t-1"},"itemId":{"S":"i-1"}}'
aws cognito-idp admin-delete-user --user-pool-id "$POOL" --username "$EMAIL"

# Verify: both should print 0
aws dynamodb scan --table-name Orders --select COUNT --query Count --output text
aws cognito-idp list-users --user-pool-id "$POOL" --query 'length(Users)' --output text
```

If `$EMAIL` is empty (for example in a new terminal), `admin-delete-user` does nothing useful. List the users with
`aws cognito-idp list-users --user-pool-id "$POOL"` and delete by the `Username` shown there (an internal ID).

### Comparing the two read paths

```bash
./scripts/compare-reads.sh            # ROUNDS=50 by default
```

It seeds one order with three items, then measures `GET /orders/{id}` (direct), `GET /orders-via-lambda/{id}` (Lambda) and
an unauthenticated request that API Gateway rejects (the gateway-only floor), **interleaved** so network drift affects every
path equally. It prints a Markdown table and always removes its temporary user and rows. Each request opens a new connection,
so compare the paths with each other, not with a browser. Results and what they mean are in the
[optimization guide](OPTIMIZATION_GUIDE.md).

## 4. Check observability

After a few calls:

- **Dashboard:** `terraform output dashboard_url` (from `terraform/environments/dev`). API Gateway `Count` and
  `4XXError`, and Lambda `Invocations` and `Errors`, should rise. Metrics can take a minute or two to appear.
- **How to read it:** a 409 or 400 raises the API's `4XXError` but **not** Lambda `Errors`, because those are handled
  responses. API-level counts are higher than Lambda's, since rejected requests never reach the function.
- **Logs:** `aws logs tail /aws/lambda/save-order --since 10m`. Entries should contain request metadata and never order contents.
- **Traces:** open X-Ray in the console. Each Lambda invocation produces one trace.

## 5. Test the pipeline

1. Make a small change on a branch (for example a README edit) and open a pull request to `main`.
2. **`validate.yml`** runs on the PR with no AWS access (formatting, validation, unit tests). It must pass before you can merge.
3. A change under `terraform/environments`, `terraform/modules`, `src` or `deploy.yml` also starts **`deploy.yml`** after the merge: a plan, then a pause for your approval in the `production` environment. Read the plan summary before approving. An unchanged deployment shows **No changes**.
4. A change that creates or updates a resource is the real test of the deploy role's write permissions. If it fails with `AccessDenied`, add the missing action in `terraform/bootstrap/main.tf` and apply the bootstrap manually, by design.

## 6. WAF rate limit (optional, billed)

Off by default. It costs about $6 per month while attached, billed hourly even when idle.

```bash
cd terraform/environments/dev
terraform apply -var enable_waf=true                      # billing starts
URL=$(terraform output -raw create_order_url)
for i in $(seq 1 250); do curl -s -o /dev/null -w "%{http_code}\n" -X POST "$URL" -d '{}'; done | sort | uniq -c
terraform apply                                           # REMOVE it again: re-apply without the variable
terraform output waf_enabled                              # must print false
```

Expect 401 (or 429) at first and then **403** once an IP passes 100 requests in 5 minutes. WAF enforcement can lag by
about a minute. Note that a push to `main` also removes the WAF, because `deploy.yml` applies with it disabled.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `401` on a request that should be valid | The ID token lasts 60 minutes: sign in again. Also check you sent the **ID** token, not the access token. |
| `403 Missing Authentication Token` | Wrong URL or stage. Use `terraform output -raw create_order_url` exactly (for reads, append `/<orderId>`). |
| `404 {"message": "Order not found"}` on a `GET` | There are no items for that `orderId`. Check spelling and the table. A hostile or odd id also gives 404, never a 500. |
| `500 {"message":"Internal error"}` on a `GET` | DynamoDB or the integration role failed. Check that the `save-order-api-read-role` role exists and still allows `dynamodb:Query` on the table. |
| `415 Unsupported Media Type` on a `GET` | A request sent a content type the template does not accept (`passthrough_behavior = NEVER`). Use `application/json` or no body. |
| `400 {"message": "Invalid request body"}` (note the space) | API Gateway's schema check: a field is missing, wrong, or extra. |
| `400` with an `errors` list | The Lambda's own validation, with the reasons. |
| `429` | The 5 requests per second throttle. Slow down. |
| `call: command not found`, or empty `$POOL`, `$URL`, `$TOK` | New terminal: re-run the setup block, or use the script. |
| `Backend initialization required` | Run `terraform init -reconfigure -backend-config="bucket=$(terraform -chdir=../../bootstrap output -raw state_bucket)"`. |
| `The security token included in the request is expired` (AWS CLI) | Run `aws sso login` again. |
| Dashboard looks empty | Metrics lag by a minute or two, and the default time range may not include your calls. |
| `node --test` finds no tests | Use the quoted glob: `node --test "src/*/*.test.mjs"`. |
| `400 {"message":"Invalid order id",...}` on `/orders-via-lambda/...` | The id failed the Lambda's allow-list (letters, numbers, `.`, `_`, `-`, 1 to 128 characters). The direct read would return 404 for the same id. |
| `iam:PassRole` access denied when deploying | A direct integration needs the permission set and the CI deploy role to pass roles to `apigateway.amazonaws.com`. See "Reading orders" in [terraform/README.md](../terraform/README.md). |
| A test user is still in the pool | Delete it by its `Username` from `list-users`; see the cleanup note in section 3. |
