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
├── frontend/                      # root config for the browser front end's hosting (its OWN state; applied locally): private bucket + CloudFront + certificate + DNS
└── modules/
    ├── dynamodb-table/            # reusable, validated DynamoDB table module
    ├── lambda-function/           # Lambda + least-privilege IAM role + log group (+ boundary, X-Ray)
    ├── rest-api/                  # REST API: Lambda proxy routes (optionally with a child path), direct DynamoDB routes, validation, throttling, Cognito authorizer
    ├── apigw-dynamodb-role/       # read-only role API Gateway assumes to query one DynamoDB table
    ├── cognito-user-pool/         # Cognito user pool + public app client
    ├── dax-cluster/               # optional DAX cluster, its role, security groups and a Logs endpoint (billed; off by default)
    ├── waf-rate-limit/            # optional WAF per-IP rate limit (billed; off by default)
    ├── api-custom-domain/         # optional regional custom domain: ACM certificate, DNS validation, mapping (multi-region)
    ├── static-site/               # private S3 bucket behind CloudFront (OAC, TLS 1.3, security headers, dedicated certificate, DNS alias, optional new web ACL)
    ├── route53-multi-region/      # optional Route 53 latency records and health checks (billed; off by default)
    └── cloudwatch-dashboard/      # API Gateway Count/4XXError, Lambda Invocations/Errors
src/save-order/                    # write Lambda: Node.js code and unit tests
src/get-order/                     # read Lambda (alternative to the direct read): Node.js code and unit tests
src/signin-guard/                  # Cognito trigger that allow-lists Google sign-ins (optional federated sign-in): code and unit tests
.github/workflows/                 # validate.yml (PRs, no AWS) and deploy.yml (push to main, OIDC + approval)
scripts/e2e-test.sh                # end-to-end smoke test with automatic cleanup
scripts/compare-reads.sh           # interleaved latency comparison: direct read vs Lambda read (cleans up)
scripts/build-dax-package.sh       # builds the read Lambda package with the DAX client (only for the optional DAX switch)
scripts/secret-scan.py             # secret / sensitive-data scanner (pre-commit hook and CI)
scripts/check-doc-links.py         # checks every Markdown link and heading anchor (CI)
scripts/demo/                      # behaviour checks for the cache, DAX, WAF, multi-region and Google sign-in demos (clean up after themselves)
scripts/benchmark/                 # cold-start and memory benchmark (temporary function, cleans up)
docs/TESTING.md                    # how to test: unit, end-to-end, observability, pipeline, WAF
docs/OPTIMIZATION_GUIDE.md         # when and why to use each optimization, with measurements, cost and security risks
docs/SECRET_SCANNING.md            # what is scanned for, how to enable the hook, limits
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
| DynamoDB Streams | **On** (`NEW_AND_OLD_IMAGES`; free to enable, nothing reads it yet; a global table needs it) |
| Global table replica | **Off** (`enable_multi_region`; billed, see [Multi-region](#multi-region-activeactive-global-table-optional-billed-off-by-default)) |

Outputs: `orders_table_name`, `orders_table_arn` (the Lambda policy is scoped to this ARN).

## save-order Lambda

Saves one order item (one row) to the Orders table.

| Setting | Value |
|---|---|
| Runtime | `nodejs24.x` (latest GA; Node.js 26 is still public preview) |
| Architecture / memory / timeout | `arm64` / 512 MB / 10 s (memory chosen from a benchmark, see the root README "Performance") |
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
| Throttling | 5 requests/second, burst 10, **per method** (the `*/*` default gives each method its own token bucket; all callers of a method share it, it is not per client). Requests rejected with 401 before the method is reached did **not** consume it in a test (see the WAF section) |
| CORS | **Off by default** (`cors_allowed_origins`, see [CORS for a browser front end](#cors-for-a-browser-front-end-optional-off-by-default) below). |
| Not enabled | Access logs (needs an account-wide CloudWatch role), X-Ray on the API stage. A custom domain exists only with the optional multi-region setup. The stage cache and the WAF are available but **off by default** (see below). |

Cost: REST API requests are about $3.50 per million. There is no charge while idle.

## CORS for a browser front end (optional, off by default)

A browser calling this API from another origin (for example `https://orders.example.com`) first sends an unauthenticated **preflight** `OPTIONS` request, and
refuses to show the response unless it carries an `Access-Control-Allow-Origin` header for that origin. `cors_allowed_origins` (empty by default, in which case nothing changes) lists the
origins that may call the API. REST APIs have no built-in CORS, so it is added in four places:

| Where | What happens | Why |
|---|---|---|
| **Preflight** | Each route's resource gets an `OPTIONS` method answered by API Gateway itself (a MOCK integration: no Lambda or DynamoDB call, nothing billed beyond the request). For a listed origin it returns `Allow-Origin` (the origin echoed), `Allow-Methods` (that route's method and `OPTIONS`), `Allow-Headers: Authorization,Content-Type` and `Max-Age: 600`; for any other origin it returns none of them. | The browser sends no credentials in a preflight, so this method has **no authorizer** and returns no data |
| **Lambda routes** (`POST /orders`, `GET /orders-via-lambda/{id}`) | The function echoes the request's `Origin` when it is on the list (`ALLOWED_ORIGINS` environment variable), on **every** response: 200, 201, 400, 404, 409 and 500 | API Gateway adds nothing to a Lambda proxy response |
| **Direct DynamoDB route** (`GET /orders/{id}`) | The response templates set the same header from the request's `Origin` | Same reason, for the non-proxy integration |
| **Errors API Gateway produces itself** (401 from the authorizer, 403, 429, request validation 400, 5xx) | Gateway responses add the header for the **first** listed origin only | A gateway response cannot choose the origin dynamically. Put the production origin first; a second origin (such as `http://localhost:8765` for development) will see these errors as an opaque network error |

Rules and trade-offs:
- **Exact origins only, never `*`.** Each must be `https://host[:port]`, or `http://localhost[:port]`, with no path or trailing slash (the module rejects anything else). A listed origin is echoed exactly; `Vary: Origin` is always added so caches do not mix origins. No credentials mode is used (the API takes a bearer token, not cookies).
- **CORS is not authentication.** It only tells browsers which sites may read responses. Every route still needs a valid token, and a non-browser client ignores CORS entirely.
- **The pipeline keeps it on.** The dev stack is applied on every merge to `main` with every optional switch off; `deploy.yml` passes the repository **variable** `CORS_ALLOWED_ORIGINS` (a JSON list such as `["https://orders.example.com","http://localhost:8765"]`, set under Settings, Secrets and variables, Actions, Variables) so a merge does not remove CORS. It is not a secret and is not committed. Unset means no CORS.
- **The second region's API** gets the same list and its Lambdas the same `ALLOWED_ORIGINS`.
- **Cost:** nothing extra (a preflight is one more request at the normal price).

```bash
cd terraform/environments/dev
terraform apply -var 'cors_allowed_origins=["https://orders.example.com","http://localhost:8765"]'
cd ../../.. && scripts/demo/cors-checks.sh        # preflight, gateway errors and real calls; cleans up after itself
```

## Reading orders: direct DynamoDB integration (`GET /orders/{orderId}`)

Reads do not use Lambda. API Gateway calls DynamoDB itself (an AWS service integration, `Query`) and maps the
request and response with VTL templates in `terraform/environments/dev/templates/`.

| Setting | Value |
|---|---|
| Method | `GET /orders/{orderId}`, same Cognito authorizer as `POST /orders` |
| DynamoDB call | `Query` on the Orders table, strongly consistent (a client reads back what it just wrote), at most 100 items |
| Request template | `get-order.request.vtl`: puts the path parameter into `ExpressionAttributeValues` as a string value (never into the query expression) and escapes it for JSON |
| Response template | `get-order.response.vtl`: turns DynamoDB's typed attributes into plain JSON, `null` for missing `quantity`/`price`, and sets **404** (through `$context.responseOverride.status`) when the order has no items |
| Errors | DynamoDB 4xx and 5xx become fixed `{"message":"Bad request"}` and `{"message":"Internal error"}` bodies; nothing from DynamoDB is passed through |
| Unmatched content types | Rejected (`passthrough_behavior = NEVER`) |
| Role | `save-order-api-read-role`: `dynamodb:Query` on the Orders table only. The `apigw-dynamodb-role` module rejects write actions and wildcards, and the role carries the pipeline's permissions boundary. |
| Timeout | 5 seconds |

Response: `{ "orderId", "itemCount", "items": [ { "itemId", "quantity", "price", "createdAt" } ] }`.

**Known gap:** orders have no owner, so **any signed-in user can read any order** if they know its ID. Per-user ownership is
not implemented (see [Known limitations and roadmap](../README.md#known-limitations-and-roadmap) in the root README).

**Limitations and trade-offs:** no pagination (one `Query`, up to 100 items), no list-all (a `Scan` would be unbounded and expose
every order). Beyond that:
- **Silent truncation:** results are cut at 100 items and `itemCount` is the number returned, so a client cannot tell the list
  was cut off (DynamoDB's continuation marker is dropped).
- **Less visibility:** no Lambda logs, no X-Ray trace and no API access logs for reads; only API Gateway's `Count` and `4XXError`
  metrics show them. Errors are deliberately generic, which protects against information leaks but makes failures harder to diagnose.
- **Not faster:** measured **30 to 40 ms slower** than the same read through a Lambda (medians 377 against 338 ms, and 352 against
  322 ms, in two interleaved runs). The benefit is no Lambda to run or pay for (about $0.25 per million requests), not latency.
- **Cost:** the strongly consistent read uses twice the read units of an eventually consistent one (about $0.06 more per million
  reads); API Gateway at $3.50 per million dominates.
The VTL templates have no unit tests. They were checked against a real DynamoDB table on a scratch API, and
`scripts/e2e-test.sh` covers the read cases against the deployed stack. See the
[optimization guide](../docs/OPTIMIZATION_GUIDE.md) for the measurements, the cost arithmetic and the security-risk table.

## Reading orders via Lambda (`GET /orders-via-lambda/{orderId}`)

The same read, done by a Lambda, so the two styles can be compared like for like.

| Setting | Value |
|---|---|
| Route | `GET /orders-via-lambda/{orderId}`, same Cognito authorizer. It has its own top-level path so it does not shadow the direct route's `{orderId}`. |
| Function | `save-order-lookup`: Node.js 24, arm64, **512 MB** (same as `save-order`), X-Ray on. The name carries the `save-order-` prefix so the pipeline's IAM scope (`save-order-*`) covers its role and function. |
| Permissions | `dynamodb:Query` on the Orders table only, plus its own log group; carries the permissions boundary |
| Query | The same as the direct read: strongly consistent, at most 100 items, the id passed as a value |
| Logic | `src/get-order/` (8 unit tests). Pure logic with the DynamoDB call injected, like `save-order`. |

**Differences from the direct read:**

| | Direct integration | Lambda read |
|---|---|---|
| Invalid id (a quote, spaces, over 128 characters) | Treated as a lookup: **404** | Validated with an allow-list: **400** |
| Truncation | Cut at 100 items with no signal | Returns `"truncated": true` when DynamoDB had more |
| Response JSON | Pretty-printed by the template | Compact |
| Logs and traces | None | Lambda logs and X-Ray traces |
| Unit-testable | No (VTL) | Yes |
| Cold start | None | Yes: init 330 ms plus a 252 ms first request, about 0.58 s, once per environment |
| Median latency (interleaved, warm) | 377 ms and 352 ms | **338 ms and 322 ms** (about 30 to 40 ms faster) |
| Cost per million reads | about $3.63 | about $3.87 |

Run `./scripts/compare-reads.sh` to repeat the latency comparison (requests are interleaved, so network drift affects both equally).
The measured results and what they mean are in the [optimization guide](../docs/OPTIMIZATION_GUIDE.md#33-direct-read-against-lambda-read-like-for-like).

**Before merging a change like this, update IAM (one-time, manual).** API Gateway checks `iam:PassRole` when a method is
given an integration role, and by default your SSO permission set and the CI deploy role may only pass roles to Lambda.
1. Update the permission set with [docs/permission-set-inline-policy.json](../docs/permission-set-inline-policy.json)
   (its pass-role statement now also allows `apigateway.amazonaws.com`), reprovision the account and run `aws sso login`.
2. Apply the bootstrap, which updates the deploy role the same way: `cd terraform/bootstrap && terraform apply`.
3. Only then merge. Without step 2 the CI deploy fails with `iam:PassRole` access denied.

**Adding a second function (this change):** the deploy role's Lambda and log-group permissions used to cover only the exact name
`save-order`. They now also cover `save-order-*`, which `save-order-lookup` needs. Apply the bootstrap
(`cd terraform/bootstrap && terraform apply`, a 1-change plan) **before merging**, or the deploy fails with access denied.
Your SSO permission set needs no change.

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

## DynamoDB Accelerator, DAX (optional, billed, OFF by default)

DAX is an in-memory cache for DynamoDB. With the switch on, the read Lambda (`save-order-lookup`) reads through a DAX cluster instead
of calling DynamoDB. **It is billed by the node-hour with no free tier**, so it is off by default.

| Setting | Value |
|---|---|
| Switch | `enable_dax` (default `false`); `dax_node_type` (default `dax.t3.small`); `dax_query_ttl_seconds` (default **60**) |
| Cluster | One node in one subnet of the default VPC, encrypted at rest, clients connect over TLS (`daxs://`, port 9111). One node is for demos only; high availability needs three. |
| What changes when on | The read Lambda moves into the VPC, gets `DAX_ENDPOINT` and `dax:Query`, and its reads become **eventually consistent** (DAX cannot cache strongly consistent reads). Nothing else changes: with the switch off the function uses DynamoDB exactly as before. |
| Roles | A read-only DAX service role (`save-order-dax-role`: `DescribeTable`, `Query`, `GetItem`, `BatchGetItem` on the Orders table); the Lambda role gets `dax:Query` on the cluster |
| Network | The Lambda has no internet access inside the VPC, so a CloudWatch Logs interface endpoint is created for its logs. Security groups allow only the Lambda to reach the cluster. |
| Package | The DAX client is not in the Lambda runtime, so `./scripts/build-dax-package.sh` installs it from a committed lockfile (install scripts disabled) into `build/get-order-dax`: 696 files, 4.8 MB (1.4 MB zipped), against about 2 KB for the default package. Terraform zips that instead only when the switch is on. |
| Approximate cost | About **$0.04 per node-hour** (AWS's example node type) plus about **$0.01 per hour** for the Logs endpoint: roughly **$0.05 per hour while on**, or about $36 a month if left running. Prices not re-verified for the node type and endpoint. |

**One-time prerequisites (manual, before the first demo):**
1. Update the permission set with [docs/permission-set-inline-policy.json](../docs/permission-set-inline-policy.json): its pass-role statement now also
   allows `dax.amazonaws.com`. Reprovision the account and run `aws sso login`.
2. Apply the bootstrap (`cd terraform/bootstrap && terraform apply`, a 1-change plan): the permissions boundary now allows the VPC network
   interface actions, `dax:Query`, `dax:GetItem`, `dax:BatchGetItem` on the cluster, and `dynamodb:DescribeTable`.

**Demo, then turn it off:**

```bash
./scripts/build-dax-package.sh                     # builds build/get-order-dax with the DAX client
cd terraform/environments/dev
terraform apply -var enable_dax=true               # billing starts; creating a cluster takes a while (about 10 to 20 minutes)
aws logs tail /aws/lambda/save-order-lookup --since 5m    # look for {"message":"read backend selected","backend":"dax",...}
cd ../../.. && ./scripts/compare-reads.sh          # repeated reads of one order: DAX hits
cd terraform/environments/dev
terraform apply                                    # REMOVE it: re-apply WITHOUT the variable
terraform output dax_enabled                       # must print false
```

**Trade-offs, read before turning it on:**
- **It cannot speed up a strongly consistent read**, which is what this API uses by default so a client reads back what it just wrote. DAX passes those
  reads straight to DynamoDB without caching them. That is why the switch also makes the read eventually consistent.
- **Stale and empty results.** DAX caches `Query` results for the TTL and does **not** invalidate them when an item is written (our writes go straight to
  DynamoDB, and even writes through DAX do not refresh the query cache). It also caches an empty result. After a `POST`, a read can show the old list, or "not found", for up to
  `dax_query_ttl_seconds`. **Confirmed in the demo:** a cached one-item order stayed one item after a second POST, and a cached 404 stayed 404 after the order was created.
- **Little to gain here.** The read function runs in about 6 ms in total, including its DynamoDB call, in a request of about 320 ms that is mostly network, so DAX can save
  at most a few milliseconds (about 1%). **Measured: it saved nothing** (Lambda read median 322 ms with and without DAX), and the cold start grew from about 0.58 s to 2.2 s.
- **More moving parts:** a VPC, security groups, an endpoint, a bundled dependency and a larger package. X-Ray traces from the function are unavailable while it is in the VPC unless an X-Ray endpoint is added (not done).
- **The pipeline cannot manage it.** The CI deploy role has no DAX or EC2 permissions, so apply and remove it locally. `deploy.yml` stops with a clear message if DAX is still in the
  state, so turn it off locally first.

See [TESTING.md](../docs/TESTING.md) for how to verify it and the [optimization guide](../docs/OPTIMIZATION_GUIDE.md) for cost and security.

## API Gateway stage cache (optional, billed, OFF by default)

A stage cache answers repeated `GET` requests without calling the backend. It is **billed by the hour even when idle and is not
free-tier eligible** (AWS's own example is $0.038 per hour for 1.6 GB; the smallest, 0.5 GB, is cheaper, about $0.02 per hour, which I could not
verify). It is off by default.

| Setting | Value |
|---|---|
| Switch | `enable_api_cache` (default `false`); `api_cache_ttl_seconds` (default **300**, allowed 1 to 3600) |
| Size | 0.5 GB, the smallest |
| What is cached | `GET` methods only: both read routes (`/orders/{orderId}` and `/orders-via-lambda/{orderId}`). `POST` is never cached. |
| Cache key | The `orderId` path parameter, set explicitly on each integration, so each id is cached separately. Without it, one order's response could be served for another. |
| Data at rest | Encrypted |
| `Cache-Control: max-age=0` | **Ignored** (`SUCCEED_WITHOUT_RESPONSE_HEADER`), so a client cannot bypass the cache and force backend calls |
| Time to create or remove | About 4 minutes |

```bash
cd terraform/environments/dev
terraform apply -var enable_api_cache=true      # create (billing starts); or run deploy.yml manually with the input ticked
terraform apply                                 # remove: re-apply WITHOUT the variable
terraform output api_cache_enabled              # check it is false when you are done
```

**Trade-offs, read before turning it on:**
- **Stale reads.** Writes do not invalidate the cache. After a `POST`, a `GET` of the same order can return the old result for up to the TTL
  (300 s). This **undoes the read-your-writes guarantee** the reads were built with (`ConsistentRead`), and **404s are cached too** (confirmed in the demo: an order created after a 404 kept returning 404). Flush it with
  `aws apigateway flush-stage-cache --rest-api-id <id> --stage-name dev`; **the flush takes about 50 s to take effect**, so a read a few seconds later can still be stale.
- **Responses are shared between signed-in users.** That matches today's behaviour (any signed-in user can read any order), but it is a
  **blocker for per-user ownership**: the cache would need the caller's identity in its key, or caching must be skipped.
- **Only repeated reads of the same order benefit.** A cache hit skips the backend; measured gain was about 21 to 23 ms (6 to 7%) on a roughly 320 ms request, because the network round trip
  (about 275 ms) remains. Unique ids never hit.
- Watch `CacheHitCount` and `CacheMissCount` (CloudWatch, namespace `AWS/ApiGateway`, dimensions `ApiName` and `Stage`) to see whether it is working.

See [TESTING.md](../docs/TESTING.md) for the steps to verify it (hit, stale read, and a check that ids are not mixed up) and the
[optimization guide](../docs/OPTIMIZATION_GUIDE.md) for cost and security.

## WAF rate limit (optional, billed, OFF by default)

A WAF web ACL with one rate-based rule blocks any IP that sends more than 100 requests in 5 minutes
(HTTP 403). It is evaluated before API Gateway, so blocked requests never reach the authorizer or Lambda.
API Gateway's own throttle (5 req/s, burst 10) is a token bucket **per method**, shared by every caller of that method; this rule is per IP.

**Why the WAF rule adds something (measured 2026-10-11, one client, one short run):**
- With a valid token, 200 rapid requests to one method got 10 through (the burst), then 171 were `429`; a trickle of about 3 requests per second to a **different** method at the same moment was untouched (15 of 15 accepted). So the buckets are separate per method.
- 200 rapid requests **without** a token all got `401` and no `429`: they were rejected before the throttle counted them, so the method throttle does **not** limit an unauthenticated flood. Whether API Gateway bills those 401s was not verified.
- Because one caller can drain a method's bucket and cause `429` for everyone else, and unauthenticated floods bypass it, a per-IP rule in front of API Gateway is the control for both.
- Separately, the **account's Lambda concurrency limit is 10** here, so about 10 or more parallel requests to a Lambda-backed route got `500` from the proxy (Lambda `Throttles` rose; the function had no errors).

**Cost:** $5.00 per web ACL + $1.00 per rule per month, **prorated hourly and billed even when idle**,
plus $0.60 per million requests. No free tier. One ACL with one rule is about $6 per month, or about
$0.008 per hour, which exceeds the $5 budget if left on. Only enable it to demonstrate.

```bash
cd terraform/environments/dev
terraform apply -var enable_waf=true     # create (billing starts). Repeat any other switch you want kept, or it is removed
terraform apply                           # remove: re-apply WITHOUT the variable
terraform output waf_enabled              # check it is false when you are done
```

Demonstrate the block (no credentials needed; WAF runs before the authorizer). Expect 401/429 at first,
then 403 once the limit is exceeded. **Enforcement lags**: in the demo, 231 requests got through (3 per second for about 80 s) before the first 403,
and the IP stayed blocked for about 5 minutes after the last request, including for valid requests (the rule is per IP). Use 300 requests, not 250, to see it:

```bash
URL=$(terraform output -raw create_order_url)
for i in $(seq 1 300); do curl -s -o /dev/null -w "%{http_code}\n" -X POST "$URL" -d '{}'; done | sort | uniq -c
```

Not enabled (each costs extra): WAF logging, managed rule groups, Bot Control, CAPTCHA.

## Multi-region, active/active: global table (optional, billed, OFF by default)

```
client -> Route 53 (latency routing, health-checked) -+-> API Gateway -> Lambda -> Orders replica   (primary region)
                                                      +-> API Gateway -> Lambda -> Orders replica   (second region, us-west-2)
                         Orders replicas keep each other in sync (DynamoDB global table, streams)
```

With `enable_multi_region` on, `Orders` becomes a **DynamoDB global table** with a writable replica in `dr_region` (default `us-west-2`),
a second copy of the API (Lambda write and read, API Gateway with the same routes) runs there, and Route 53 sends each client to the
nearest healthy region at one name. Either region can take reads and writes, and if one fails, DNS stops answering with it.

| Setting | Value |
|---|---|
| Switch | `enable_multi_region` (default `false`); also needs `multi_region_domain` (for example `api.example.com`) and `route53_zone_name` (an **existing** public hosted zone, for example `example.com`). Pass both at apply time; they are not committed. |
| Table | Streams on (`NEW_AND_OLD_IMAGES`), one replica in `dr_region`. The replica is not deletion protected, so the switch can remove it; the primary keeps its protection. Point-in-time recovery follows the primary's setting. |
| Second stack | `save-order-dr`, `save-order-lookup-dr`, `save-order-api-read-role-dr` and an API with the same routes, each reading and writing its **own region's** replica. IAM names are global, hence the suffix (still inside the `save-order-*` scope). Same permissions boundary, 512 MB, X-Ray, throttling. The WAF rate limit is attached to the second API too when `enable_waf` is on. |
| Names | A regional custom domain with a free ACM certificate in **each** region; Route 53 holds two latency alias records for the one name, each with a health check. Only records for that one name and the certificate validation are added; **existing records are never changed**. |
| Health route | `GET /health` on each API: no token (a checker has none), answered by API Gateway itself (a MOCK integration; no Lambda or DynamoDB call) and returns `{"status":"ok","region":"..."}`. It shows that the regional API Gateway is up, **not** that DynamoDB or Lambda work. |
| Sign-in | **One Cognito user pool, in the primary region.** The second API validates tokens against it. Users are not shared with a second pool (Cognito's own [multi-Region replication](https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-multi-region.html) would share them, but needs the Essentials or Plus plan and a multi-Region KMS key, so it is not used here), so new sign-ins depend on the primary region; tokens already issued keep working in the second region while the primary is down. **Verified in the demo:** the second region's API accepted a token from the primary-region pool (404 for a missing order; 401 without a token). With `enable_federated_signin` also on, a second pool exists in the second region and both APIs trust both pools (see [Sign-in with Google](#sign-in-with-google-optional-off-by-default)); see also [DISASTER_RECOVERY.md](../docs/DISASTER_RECOVERY.md). | |
| Permissions | Bootstrap: the permissions boundary now also covers the second region's table and Lambda log groups (apply the bootstrap once, a one-resource change). The demo is applied **locally**; the deploy role has no second-region, Route 53 or ACM access, and `deploy.yml` stops with a clear message if the setup is still in the state. |

```bash
cd terraform/bootstrap && terraform apply          # once: the boundary change (1 resource)
cd ../environments/dev
terraform apply -var enable_multi_region=true -var multi_region_domain=api.example.com -var route53_zone_name=example.com
terraform apply                                    # REMOVE it: re-apply WITHOUT the variables
terraform output multi_region_enabled              # must print false
```

Creating it takes a few minutes (replica creation and two certificate validations); the replica copies existing items.

**Cost.** Off by default, because it bills with no free tier on the new parts: every write is charged again in the replica region
(replicated write units, about the same price as a write), storage is charged there, the second stack adds its own request charges,
and each Route 53 health check is a monthly charge (prorated; an HTTPS check costs more than the basic one, roughly $1 to $2 a month each,
not verified) plus about $0.60 per million DNS queries. A short demo costs cents; left on it is roughly a few dollars a month for an idle table.
The hosted zone is already paid for by the existing site.

**Trade-offs, read before turning it on:**
- **Last writer wins.** Concurrent writes to the *same* item in two regions resolve by timestamp; one write is silently lost. Orders are keyed by
  `orderId` and `itemId`, so conflicts need the same item written in both regions at once. Anything that must not lose writes (counters, balances)
  needs a different design.
- **Replication is asynchronous**, usually about a second. A read in the other region right after a write there can miss it, and **strongly
  consistent reads only apply inside one region**. Do not read-after-write across regions.
- **DNS failover is not instant.** The health check needs about 90 s (three 30 s checks) to fail, and clients keep the old answer until the 60 s
  alias TTL ends, so expect roughly 1.5 to 3 minutes for a real failure. A *forced* failure (inverting a check) moved the domain in 31 s in the demo, because
  it skips detection. Clients that cache DNS longer take longer.
- **Measured replication lag** was 0.3 to 1.2 s in both directions (CloudWatch `ReplicationLatency`: average 569 ms, maximum 903 ms). A conflicting write to the
  same item in both regions converged to the later write everywhere; the other was lost.
- **The health route is shallow**: a region with a broken Lambda or table still looks healthy. A deeper check would call a real read.
- **Shared fate for sign-in** (one user pool) unless Google sign-in is also on, which gives each region its own pool, and for the stack's definition (one Terraform state).
- **Cross-region cost and compliance:** orders now live in two regions; check data-residency rules before using real data.
- **Delete handling:** deleting the replica needs the switch off; the global table keeps working in the remaining region.

See [TESTING.md](../docs/TESTING.md) for the replication, conflict and failover checks.

## Front end app (`src/frontend`)

A small page in **plain JavaScript** (ES modules, no build step, no dependencies) served from the [hosting](#front-end-hosting-separate-stack-applied-locally) above. Signed-in users can create an order item, and look an order up with the direct read, the Lambda read, or both side by side with each one's response time.

| File | Job |
|---|---|
| `index.html`, `error.html`, `styles.css` | The page, the 404 page and the stylesheet (light and dark, keyboard and screen-reader friendly, no inline script or style: the Content Security Policy forbids them) |
| `config.js` | Reads and validates `/config.json` (generated from the deployed stack); names the bad setting, never its value |
| `pkce.js`, `auth.js` | The sign-in: authorization code flow with PKCE on Cognito's hosted pages; the token exchange; an in-memory session |
| `api.js` | The calls: the ID token goes in the `Authorization` header (no `Bearer`), every failure becomes a safe message (400, 401, 404, 409, 429, 5xx, network) and a 401 ends the session |
| `orders.js` | Input checks that mirror the API's rules (the API still validates), table rows, and the direct-versus-Lambda comparison |
| `view.js`, `app.js` | The thin DOM layer and the wiring |

**How it protects users:**
- **No password in the page.** The user types it on Cognito's pages; the page gets a one-time code and exchanges it with a **PKCE verifier** it generated, so an intercepted code is useless. The `state` value is checked, and a mismatch stops the sign-in.
- **Tokens in memory only.** Not in `localStorage` or cookies. Only the one-time PKCE values survive the redirect, in `sessionStorage`, and they are deleted as soon as they are read. A reload signs the user out, and the hosted pages sign straight back in while Cognito's own session is alive. **No refresh token is kept**: the session lasts the ID token's life (about an hour).
- **No XSS from the API.** Everything shown is set with `textContent`; no HTML string is ever parsed, so an order ID or error message cannot become markup or script. The CSP (no inline script, `connect-src` limited to the API and the sign-in host, no framing) is a second layer.
- **The code is removed from the address bar** immediately (`history.replaceState`); the page refuses to run if its configuration is for a different address; the token is never put in a URL, a log or a message.

```bash
# 1. Run it locally against the REAL API and sign-in (http://localhost:8765/ is a registered callback and CORS origin):
scripts/dev-frontend.py                 # same security headers as production, so CSP problems show in the browser console
# 2. Create a user to sign in with (users are created by an administrator; there is no sign-up). Choose the password at the silent prompt:
cd terraform/environments/dev && POOL=$(terraform output -raw user_pool_id) && cd ../../..
aws cognito-idp admin-create-user --user-pool-id "$POOL" --username you@example.com --user-attributes Name=email,Value=you@example.com Name=email_verified,Value=true --message-action SUPPRESS
read -rs PW && aws cognito-idp admin-set-user-password --user-pool-id "$POOL" --username you@example.com --password "$PW" --permanent && unset PW
# 3. Publish it (runs the unit tests first, uploads with cache headers, refreshes CloudFront):
scripts/deploy-frontend.sh --dry-run    # lists what would change; then without --dry-run
scripts/demo/frontend-checks.sh         # now all checks run, including the real 200 and 404
```

Cache headers: HTML revalidates every time (`no-cache`); scripts and styles are cached for 5 minutes; every deploy invalidates the CloudFront cache. Delete the test user afterwards with `aws cognito-idp admin-delete-user` if you do not want it.

## Front end hosting (separate stack, applied locally)

`terraform/frontend/` hosts the browser app at its own name (for example `orders.example.com`): a **private** S3 bucket served only through CloudFront. It is a **separate Terraform root with its own
state** (`frontend/terraform.tfstate`), so the pipeline never sees it (the deploy role can only touch the `dev/` prefix) and a merge cannot remove it. It only **adds** resources; it never references or edits the existing
static website's distribution, web ACL, buckets, certificate or DNS records.

```
viewer --HTTPS (TLS 1.3, HTTP/3)--> CloudFront --signed request (OAC)--> private S3 bucket (versioned, encrypted, TLS-only)
                                       |                                  config.json (public settings, managed here)
                                       +-- security headers (CSP, HSTS, no-sniff, frame DENY, referrer, permissions, COOP, CORP)
```

| Piece | Detail |
|---|---|
| Bucket | All four Block Public Access settings, versioning, SSE-S3, owner enforced, old versions expire after 90 days. The policy lets **only this distribution** read (`AWS:SourceArn`) and denies non-TLS. |
| CloudFront | Origin access control (not the legacy identity), redirect to HTTPS, GET and HEAD only, compressed, `Managed-CachingOptimized`, HTTP/2 and 3, IPv6, price class 100, minimum **TLS 1.3**, a missing file returns a real 404 (`/error.html`). |
| Security headers | A response-headers policy: **CSP** (`default-src 'none'`; scripts, styles, images and fonts only from itself; `connect-src` only itself, **the API and the Cognito hosted domain**; `frame-ancestors 'none'`; no inline script or style, so the page must ship its JavaScript and CSS as files), HSTS for 2 years, `nosniff`, frame DENY, a strict referrer policy, a restrictive `Permissions-Policy`, and same-origin COOP and CORP. |
| Certificate | A **dedicated** ACM certificate for exactly this name (free), DNS-validated in your existing zone (one extra validation record); nothing shared with the other site's certificate. |
| DNS | Only the `A` and `AAAA` alias records for the new name (and the validation record). `allow_overwrite = false`: if the name already has a record, the apply fails instead of replacing it. |
| `config.json` | The page's public settings (API URL, Cognito hosted host, browser client ID, redirect URI), generated from the dev stack's outputs so it always matches; `no-cache`. **No secrets**: anyone can read it. The page's own files are uploaded by a script, not by Terraform. |
| Web ACL | **Off by default** (`enable_waf`): a NEW per-IP rate rule that bills about $6 a month and protects only the static files, not the API. |
| Alarm | A free CloudWatch alarm when the distribution serves more than 10,000 requests in an hour (an early warning of a traffic flood; no action attached). |

**Cost:** about $0 to a dollar a month: CloudFront inside its always-free allowance (shared across the account), S3 pennies, Route 53 pennies, the certificate free, no web ACL. A flood is the only way to a bigger bill (pay-as-you-go has no overage cap); the alarm and the $5 budget warn, and a CloudFront flat-rate plan (no overage charges, WAF included) is an option to evaluate later.

**Stops with a clear message** (preconditions) if: the name is outside the zone, is the zone itself or `www`; the dev stack has no browser sign-in; the API does not list this origin in `CORS_ALLOWED_ORIGINS`; or the browser client does not list `https://<name>/` in `BROWSER_CALLBACK_URLS`.

```bash
cd terraform/frontend
cp terraform.tfvars.example terraform.tfvars                      # then edit: your name, your zone, the state bucket (git-ignored)
terraform init -backend-config="bucket=$(terraform -chdir=../bootstrap output -raw state_bucket)"
cd ../.. && scripts/demo/static-site-snapshot.sh save            # BEFORE: read-only fingerprints of the existing website
cd terraform/frontend && terraform plan                          # must show only additions (18), no change and no destroy
terraform apply                                                  # a few minutes (certificate validation, distribution deployment)
cd ../.. && scripts/demo/static-site-snapshot.sh compare         # AFTER: must say NOTHING about the existing site changed
scripts/demo/frontend-checks.sh                                  # HTTPS, TLS 1.3, headers, private bucket, config.json, 404s
```

**If the first apply stops** with `Provider produced inconsistent final plan` about `cache_policy_id`: an earlier version made the module wait on the checks object, which deferred the managed cache-policy lookup to apply time and the AWS provider mishandled the unknown value. It is fixed (no `depends_on`); the partial apply is safe (13 of 18 resources were created) and re-running `terraform apply` finishes the remaining 5.

Remove it with `terraform destroy` in `terraform/frontend` (the bucket must be empty; it is versioned, so delete all versions first). The DNS records and the certificate go with it.

## Hosted sign-in for a browser front end (optional, off by default)

Cognito's **hosted sign-in pages** let a browser app sign users in without handling passwords itself: the app redirects to the pages, the user signs in, and Cognito redirects back with a one-time code that the app
exchanges for tokens (the **authorization code flow with PKCE**). Everything here is free on the Lite plan, and it needs no Google account and no secrets.

| Setting | Value |
|---|---|
| Switches | `cognito_domain_prefix` (empty by default: the hosted pages stay off) and `browser_callback_urls` (empty: no browser client). The pipeline reads the repository **variables** `COGNITO_DOMAIN_PREFIX` (a plain string) and `BROWSER_CALLBACK_URLS` (a JSON list), so a merge does not remove them; neither is a secret and neither is committed. |
| Hosted domain | `<prefix>.auth.<region>.amazoncognito.com`: lower-case letters, numbers and hyphens, unique per region across all AWS accounts, and it may not contain `aws`, `amazon` or `cognito`. The same domain is shared with Google sign-in; if both are on, `federated_domain_prefix` must equal `cognito_domain_prefix`. |
| Browser client | `<pool>-browser-client`: public (no secret), authorization code flow only (no implicit flow), scopes `openid email`, identity provider Cognito (username and password), **exact** callback and sign-out URLs from `browser_callback_urls` (`https://host/[path]`, or `http://localhost:port/` for development; no wildcards), token revocation on. The ID token it yields is the one the API's authorizer already validates. |
| Users | Still created by an administrator (no self sign-up); the hosted pages show no sign-up link. MFA stays optional TOTP. |
| Untouched | The password (CLI) client and the Google client |

```bash
# set the repository variables (Settings, Secrets and variables, Actions, Variables), then merge so the pipeline applies; or locally:
cd terraform/environments/dev
terraform apply -var cognito_domain_prefix=<prefix> -var 'browser_callback_urls=["https://orders.example.com/","http://localhost:8765/"]'
terraform output browser_signin          # host and client id: public values the front end needs (generated into its config)
cd ../../.. && scripts/demo/hosted-signin-check.py   # signs a temporary user in on the hosted pages with no browser; cleans up
```

**One-time bootstrap apply:** the pipeline's deploy role needs `cognito-idp:DescribeUserPoolDomain` (it cannot be scoped to a pool), so run `cd terraform/bootstrap && terraform apply` (a one-resource change) **before** the pipeline first applies the hosted domain.
Without it the apply fails while waiting for the domain and, because the domain was created but not recorded cleanly, Terraform marks it **tainted** (it would be destroyed and recreated at the next apply): untaint it with `terraform untaint 'module.orders_user_pool.aws_cognito_user_pool_domain.this[0]'`, apply the bootstrap, then re-run the deploy.

Notes: callback URLs are matched **exactly** (a missing trailing slash is a different URL); the user's session is the ID token (about an hour) and a refresh token (7 days), so the front end should keep tokens in memory or session storage; set the repository variables **before** merging, or the merge applies without them (a re-run of the deploy then picks them up).

## Sign-in with Google (optional, off by default)

With `enable_federated_signin` on, people sign in with a Google account through Cognito's hosted pages, and the APIs accept the pool's ID token exactly as before.
A **sign-in guard** Lambda lets only the addresses you list in. Nothing changes while the switch is off; the password client and CLI test users keep working either way.

```
browser -> Cognito hosted pages -> Google (consent screen in Testing mode) -> Cognito issues the pool's ID token -> API Gateway
                                    pre sign-up trigger: refuses an address that is not on the list (no profile is created)
                                    pre token generation trigger: runs on EVERY sign-in and refresh (a removed address is locked out)
```

| Setting | Value |
|---|---|
| Switch | `enable_federated_signin` (default `false`). Needs `federated_domain_prefix`, `google_client_id`, `google_client_secret` and `allowed_emails` at apply time. |
| Cognito | Classic hosted UI on `<prefix>.auth.<region>.amazoncognito.com`, Google as an identity provider, and a **separate** public app client (`...-federated-client`): authorization code flow with PKCE only, scopes `openid email profile`, Google only (no password sign-in on the hosted pages, no implicit flow). The existing password client is untouched. |
| Guard | `save-order-signin-guard` (`src/signin-guard`): 128 MB, 5 s (Cognito's limit), no AWS permissions beyond its own logs. Pre sign-up: federated users must be on the list and not explicitly unverified; administrator-created users (the CLI test users) pass; self sign-up and anything unknown are refused. Pre token generation: federated users are re-checked on every token, so removing an address also blocks refresh. It fails closed (an empty list admits nobody), says nothing about why, and never logs an email. |
| Plan | Lite supports all of this (social sign-in, classic hosted UI, Lambda triggers); the free 10,000 monthly active users apply per account and include social sign-ins. |
| With multi-region | A second pool (`orders-api-users-dr`, not deletion protected) and guard run in `dr_region`, and **both APIs trust both pools**: a client signed in through either region's pool works against either API, so sign-in no longer depends on one region. |
| Pipeline | Applied locally. A push to `main` applies with the switch off and removes the hosted domain, provider, app client and guard (the deploy role can; it is scoped to `save-order-*` and the user pools). The second region's pieces are covered by the multi-region guard in `deploy.yml`. |

**One-time Google setup (free, about 15 minutes):**
1. In the Google Cloud console create a project; set up the OAuth consent screen with audience **External**, publishing status **Testing**, your address(es) under **Test users**, and the default scopes (`openid`, `email`, `profile`).
2. Create an OAuth client of type **Web application** with these Authorized redirect URIs (the prefix is the one you choose):
   `https://<prefix>.auth.us-east-1.amazoncognito.com/oauth2/idpresponse` and, for multi-region, `https://<prefix>.auth.us-west-2.amazoncognito.com/oauth2/idpresponse`.
3. Keep the **client secret** out of the repository and out of chat: it goes only in your shell (below), and it is stored in the Terraform state (private, encrypted bucket).

```bash
cd terraform/environments/dev
export TF_VAR_google_client_secret='...'                 # the secret: shell only
export TF_VAR_allowed_emails='["you@example.com"]'          # personal data: shell only
terraform apply -var enable_federated_signin=true -var federated_domain_prefix=<prefix> -var google_client_id=<client id>
#   add -var enable_multi_region=true ... to also create the second region's pool (see the multi-region section)
cd ../../.. && scripts/demo/google-signin.py --private   # opens a PRIVATE window: sign in with an ALLOWED address; saves the tokens (mode 0600)
scripts/demo/federated-checks.sh                         # accepted by the APIs, write and read back
cd terraform/environments/dev && terraform apply         # REMOVE it: re-apply WITHOUT the variables
terraform output federated_signin_enabled                # must print false
scripts/demo/google-signin.py --forget                   # delete the saved tokens
```

**Trade-offs and security notes, read before turning it on:**
- **Without the guard, any Google account could sign in** (Cognito creates the user automatically). The guard is therefore mandatory: Terraform refuses the switch without it, and the Google consent screen should stay in Testing mode with only your test users.
- **The allow-list is an environment variable** on the guard (visible to administrators in the console and in state). It is personal data, not a credential, but keep it out of the repository.
- **Google users stay in the pool** after the switch is turned off (the primary pool is deletion protected); delete them with `aws cognito-idp admin-delete-user` if you want them gone.
- **Same person, different ids.** Each pool gives the same Google user a different Cognito `sub`. When per-user ownership of orders is built, it must key on the Google email or the Google subject, not the Cognito `sub`.
- **Browser flow.** Token requests use a browser redirect to `http://localhost:8765/callback`; the helper script stores tokens (credentials) in `~/.cache/orders-api/`. The ID token lasts about an hour; the refresh token about 7 days. Use `--private` (a normal window reuses your existing Google session), keep the terminal open until it says "Saved tokens", and never reuse a callback link: it works once.
- **Removing an address stops new tokens, not existing ones.** Verified: a refresh was refused after removal, but an ID token issued earlier still worked until it expired (up to 60 minutes). For an immediate cut-off also run `aws cognito-idp admin-user-global-sign-out` and `admin-disable-user`, or shorten the token lifetime.
- **Verified live (2026-10-10 and 11),** including with two regions; the step-by-step procedure and results are in [COGNITO_TESTING_RUNBOOK.md](../docs/COGNITO_TESTING_RUNBOOK.md).
- **In Testing mode Google expires refresh tokens after 7 days** and only the listed test users can sign in.
- The hosted domain prefix is unique per region across all AWS accounts; Terraform fails if it is taken.

## Cognito user pool

| Setting | Value |
|---|---|
| Tier | `LITE`: 10,000 monthly active users free, permanently. `PLUS` is rejected (no free tier). |
| Sign-up | Admin-created users only (no self sign-up). With the optional [Google sign-in](#sign-in-with-google-optional-off-by-default), Cognito also creates a user on a Google user's first sign-in, but only if the guard Lambda allows the address |
| Sign-in | Email address; strong password policy (12+ characters, upper, lower, number, symbol) |
| MFA | Optional, app-based TOTP only (free). SMS MFA is billed and not configured. |
| App client | Public (no secret), `USER_PASSWORD_AUTH` for CLI testing; user-existence errors hidden; token revocation on. With Google sign-in a **second** client is added (code flow with PKCE, Google only, no password) and the first is untouched |
| Tokens | ID and access tokens 60 min, refresh token 7 days |
| Deletion protection | On. Set `deletion_protection_enabled = false` and apply before `terraform destroy`. |

Terraform does not create users, so no password ever lands in state. (With the optional [Google sign-in](#sign-in-with-google-optional-off-by-default), Google users are created by Cognito on their first sign-in.) Create a test user:

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

See the [testing guide](../docs/TESTING.md) for every level, including `./scripts/e2e-test.sh`, which runs the
API's success and failure cases against the deployed stack and removes its own test data. The three Lambdas and the front end have 105 unit tests (62 and 43) using Node's built-in runner (no dependencies, Node 22+). The AWS call is
injected, so no AWS access is needed. CI runs them on every pull request.

```bash
node --test "src/*/*.test.mjs"
```

## AWS account prerequisites (your SSO permission set)

`PowerUserAccess` cannot manage IAM, but Terraform must create the Lambda execution role and, once, the
bootstrap resources. Add [docs/permission-set-inline-policy.json](../docs/permission-set-inline-policy.json) as an
inline policy on the permission set (IAM Identity Center -> Permission sets -> PowerUserAccess -> Inline
policy), reprovision the account, and run `aws sso login` again. The file uses `ACCOUNT_ID` as a placeholder so
the account ID is not published (the pass-role statement also allows `dax.amazonaws.com`, needed only for the optional DAX demo); print a ready-to-paste copy with:

```bash
sed "s/ACCOUNT_ID/$(aws sts get-caller-identity --query Account --output text)/" docs/permission-set-inline-policy.json
```

 It only allows IAM on `save-order-*` and
`serverless-api-pipeline-*` roles and the pipeline boundary policy.

**No further permission-set change was needed** for the optional multi-region and Google sign-in features: the second region's roles and functions are named inside the `save-order-*` scope
(`...-dr`), and the DynamoDB replica, Route 53, ACM and Cognito calls fall under `PowerUserAccess` (verified when they ran). What they do need is the **bootstrap apply** that widens the
permissions boundary to the second region's table and log groups (a one-resource change), and they are applied **locally**: the pipeline's deploy role has no second-region, Route 53 or ACM access.

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
- **The apply job gets the Lambda zips from the plan job.** It runs on a fresh machine, and Terraform reads each function's zip
  when it creates or updates the function. The plan job stages the plan and the zips (built in the hidden `.build` folder)
  into one artifact, with `include-hidden-files: true`, and the apply job unpacks them into `terraform/`. Without this, a
  deploy that creates or changes a function's code fails with `reading ZIP file ... no such file or directory` (a deploy that
  only changes configuration, such as memory, does not need the zip, so the gap stayed hidden until a new function).
- **Packaging is Terraform.** `archive_file` zips each function's folder under `src/`; `apply` updates a Lambda when its code hash
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
- **WAF and cache caveat.** `deploy.yml` applies with `enable_waf=false` and `enable_api_cache=false` unless you run it manually
  with the input ticked. A push to `main` therefore **removes** a WAF or a stage cache you enabled by hand, which is the safe default
  for billed features. Enable them through the workflow dispatch inputs.
- **First CI runs may report `AccessDenied`.** The deploy role's policy is resource-scoped and was written
  without being able to test it from CI. Add the missing action in `terraform/bootstrap/main.tf` and apply it manually.
- Actions are **pinned by commit SHA** (the repo requires it). Update the SHA and the version comment together.
- **Runners are pinned to `ubuntu-24.04`, not `ubuntu-latest`.** `ubuntu-latest` is moving to Ubuntu 26.04 from October 19,
  2026, which would change the machine that runs CI and the approval-gated deploy with no change in this repository. Pinning
  keeps builds reproducible. To upgrade, change `runs-on` in `validate.yml` and `deploy.yml` to `ubuntu-26.04` after testing
  it (the validate workflow can be run on a throwaway branch); GitHub keeps older images available for a long period, so
  there is no rush, but remember to move before the pinned image is retired.

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

**The optional switches** (`enable_api_cache`, `enable_dax`, `enable_waf`, `enable_multi_region`, `enable_federated_signin`) are command-line variables, and **every apply replaces the whole set**:
repeat each switch you want to keep, or Terraform removes it. A plain `terraform apply` turns them all off. Secrets and personal data (`google_client_secret`, `allowed_emails`) go in
`TF_VAR_...` environment variables in your shell, never on the command line or in a file. The multi-region and Google steps are in their sections and in
[COGNITO_TESTING_RUNBOOK.md](../docs/COGNITO_TESTING_RUNBOOK.md).

**Outputs** (`terraform output`; none is secret, and null outputs are not stored, so they are missing when their feature is off):

| Output | Meaning |
|---|---|
| `orders_table_name`, `orders_table_arn` | The Orders table |
| `save_order_function_name`, `save_order_function_arn` | The write Lambda |
| `create_order_url`, `get_order_url`, `get_order_via_lambda_url`, `rest_api_id` | The API (primary region) |
| `user_pool_id`, `user_pool_client_id` | The Cognito pool and its password client |
| `dashboard_url` | The CloudWatch dashboard |
| `dax_enabled`, `api_cache_enabled`, `waf_enabled`, `waf_web_acl_arn` | State of the cache, DAX and WAF switches |
| `multi_region_enabled`, `dr_create_order_url`, `multi_region_health_check_ids` | Multi-region switch, the second region's API URL and the health check IDs (null when off) |
| `federated_signin_enabled`, `federated_signin`, `dr_user_pool_id`, `dr_user_pool_client_id` | Google sign-in switch, the hosted host and browser client per region (used by `scripts/demo/google-signin.py`), and the second region's pool |

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
- `enable_api_cache` — the API Gateway stage cache, billed by the hour while on (about $0.02 per hour for 0.5 GB, unverified); off by default.
- API access logs, WAF logging and managed rule groups — not enabled.
- `enable_multi_region` — the global table replica, a second-region API stack and Route 53 health checks and records; billed (replicated writes, storage, health checks); off by default.
- `enable_federated_signin` — sign-in with Google and the guard Lambda; free at this scale (Cognito Lite, Lambda free tier); off by default.
- `enable_dax` — a DAX cluster plus a Logs endpoint, billed per hour while on (about $0.05 per hour, with no free tier); off by default. The read Lambda joins the VPC only while it is on.
- Dead-letter queue, CloudWatch alarms — not enabled.
