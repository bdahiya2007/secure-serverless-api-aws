# Secure Serverless Orders API on AWS

A small serverless API built the way a production one should be: authenticated, validated, least-privilege,
observable, and deployed through a pipeline that holds no AWS keys. Everything is Terraform.

[![Validate](https://github.com/bdahiya2007/secure-serverless-api-aws/actions/workflows/validate.yml/badge.svg)](https://github.com/bdahiya2007/secure-serverless-api-aws/actions/workflows/validate.yml)
[![Deploy](https://github.com/bdahiya2007/secure-serverless-api-aws/actions/workflows/deploy.yml/badge.svg)](https://github.com/bdahiya2007/secure-serverless-api-aws/actions/workflows/deploy.yml)

An authenticated client sends `POST /orders`. API Gateway checks the Cognito token and the request shape, a
Node.js Lambda validates it again and writes one item to DynamoDB, and the result is traced and charted.

## Architecture

```mermaid
flowchart LR
  C["Client"] -->|"1. sign in"| CG["Amazon Cognito<br/>user pool"]
  C -->|"2. POST /orders<br/>+ ID token"| WAF["AWS WAF rate limit<br/>(optional, off by default)"]
  WAF -.-> APIGW
  C --> APIGW["API Gateway REST API<br/>Cognito authorizer<br/>schema validation<br/>throttling"]
  APIGW --> L["Lambda: save-order<br/>Node.js 24, arm64"]
  L --> D[("DynamoDB: Orders<br/>on-demand")]
  L -.-> X["X-Ray traces"]
  APIGW -.-> CW["CloudWatch dashboard"]
  L -.-> CW
```

**Delivery pipeline:** nothing reaches AWS without a reviewed pull request, and nothing changes AWS without an approval.

```mermaid
flowchart LR
  PR["Pull request"] --> V["validate.yml<br/>fmt, validate, unit tests<br/>no AWS access"]
  V --> M["Merge to main"]
  M --> P["deploy.yml: plan<br/>short-lived OIDC credentials"]
  P --> A{"Manual approval<br/>production environment"}
  A --> AP["apply the saved plan"]
```

## What this demonstrates

- **Infrastructure as code, modular:** six reusable Terraform modules with validated inputs and plan-time guardrails.
- **Security by default:** least-privilege IAM, a permissions boundary, no stored credentials, defense in depth on input.
- **Cost awareness:** idle cost is about $0, and every billed feature is off until deliberately enabled.
- **Delivery discipline:** PR validation without AWS access, OIDC to AWS, manual approval, remote locked state.
- **Operability:** a CloudWatch dashboard, X-Ray tracing, structured logs with bounded retention.

## Security design

| Area | What is in place |
|---|---|
| **Authentication** | Cognito user pool (Lite tier), admin-created users only, strong password policy, optional TOTP MFA. API Gateway rejects requests without a valid ID token before the Lambda runs. |
| **Input handling** | The API validates the body against a JSON Schema, and the Lambda validates again with an allow-list of fields. Malformed JSON and unknown fields get a 400 that never echoes the input. |
| **No overwrites** | Writes use a condition expression, so an existing `orderId` + `itemId` returns 409 instead of being replaced. |
| **Least-privilege IAM** | The Lambda role can `PutItem` on one table ARN and write to its own log group. The module rejects `*` actions and resources at plan time, with one documented exception (X-Ray write actions cannot be scoped). |
| **Permissions boundary** | Every role the pipeline creates must carry a boundary that caps it at logging, X-Ray writes and Orders table data access. |
| **Pipeline identity** | GitHub OIDC with short-lived tokens, no stored keys. The trust policy pins the repository by immutable ID and allows only `main` (plan) and the `production` environment (apply). Pull requests cannot assume it. |
| **Pipeline cannot elevate itself** | The deploy role, boundary and state bucket live in a separately applied `bootstrap` stack. Explicit denies stop the role editing itself or removing the boundary. |
| **State** | Private, versioned, encrypted S3 bucket with TLS-only access and native locking. State and variable files are never committed. |
| **Account hardening** | S3 Block Public Access on for the whole account, deletion protection on the table and user pool. |
| **Repository** | Branch protection (admins included), required pull requests, secret scanning with push protection, GitHub Actions pinned by commit SHA. |
| **Leak prevention** | A pre-commit hook and a CI job scan for credentials, AWS account and resource IDs, personal data and state or key files, and redact what they report ([details](docs/SECRET_SCANNING.md)). |
| **Error and log hygiene** | 500 responses are generic, and logs record the error type and request ID, never order contents. |

## Cost awareness

Built and run in a personal AWS account, so cost is a design constraint. Idle cost is effectively zero:
DynamoDB is on-demand, Lambda and Cognito Lite sit inside their free tiers, and dashboards and metrics use only
free AWS-published data. Anything billed is off by default and documented:

| Feature | Approximate cost | State |
|---|---|---|
| AWS WAF per-IP rate limit | About $6/month while attached, billed hourly | Off (`enable_waf`) |
| DynamoDB point-in-time recovery | Per GB stored | Off |
| REST API requests | About $3.50 per million | On, pennies at this scale |

## Repository layout

```
terraform/
├── bootstrap/            # applied manually: state bucket, permissions boundary, CI deploy role
├── environments/dev/     # root configuration for the dev environment
├── modules/              # dynamodb-table, lambda-function, rest-api, cognito-user-pool,
│                         # waf-rate-limit, cloudwatch-dashboard
└── README.md             # full technical reference and runbook
src/save-order/           # Lambda source and unit tests
scripts/e2e-test.sh       # end-to-end smoke test with automatic cleanup
scripts/secret-scan.py    # secret and sensitive-data scanner (pre-commit hook and CI)
scripts/benchmark/        # cold-start and memory benchmark (temporary function, cleans up)
.github/workflows/        # validate.yml and deploy.yml
docs/                     # TESTING.md, SECRET_SCANNING.md and the IAM policy for the engineer's SSO permission set
```

## Try it

Setup, deployment and the cost switches are documented in the [Terraform reference](terraform/README.md),
including how to create a test user. Once deployed, a call looks like this:

```bash
curl -X POST "$API_URL/orders" \
  -H "Authorization: $ID_TOKEN" -H "Content-Type: application/json" \
  -d '{"orderId":"o-1001","itemId":"i-1","quantity":2,"price":9.99}'
```

| Response | Meaning |
|---|---|
| `201` | Saved |
| `400` | Rejected by API Gateway or the Lambda: invalid body |
| `401` | Missing or invalid token |
| `409` | That order item already exists |

The full [testing guide](docs/TESTING.md) covers unit tests, an end-to-end script that cleans up after itself,
observability checks and the pipeline. The Lambda logic has 15 unit tests using Node's built-in runner and no
dependencies:

```bash
node --test "src/save-order/*.test.mjs"
```

## Performance

The Lambda was tuned from measurements, not assumptions. The brief was to shrink the deployment package and keep
initialization out of the handler. Both turned out to be already true, and the benchmark showed where the real
latency was.

**Already in place**
- **Package: 2,089 bytes zipped** (two source files). The AWS SDK comes from the Lambda runtime and the tests are
  excluded, so there is almost nothing left to remove.
- **Initialization is outside the handler.** The DynamoDB client and `TABLE_NAME` are created at module level, once
  per execution environment, not per request.

**Method.** A temporary copy of the function (same role, `nodejs24.x`, arm64, X-Ray active tracing) was benchmarked
so production was never touched. The matrix was 3 code variants x 3 memory sizes, with 10 forced cold starts and
5 warm requests per configuration. Every request was a real DynamoDB write. Timings come from Lambda's own report
line (`Init Duration` and `Duration`), and a sample counts as cold only if it has an init phase. In all, 135 invocations
(86 cold, 49 warm); the table shows medians.

| Variant | What it changes |
|---|---|
| `baseline` | The production code |
| `slim-imports` | Low-level DynamoDB client only (drops `lib-dynamodb`) to load fewer modules |
| `init-warmup` | `slim-imports` plus client timeouts and credentials/region resolved during init |

**Results**

| Variant | Memory | Cold samples | Init (ms) | First request (ms) | **Cold total (ms)** | vs current | Cold p90 (ms) | Warm (ms) | GB-s per cold request |
|---|---|---|---|---|---|---|---|---|---|
| baseline (current) | 128 MB | 10 | 308 | 983 | **1,281** | | 1,322 | 70 | 0.160 |
| slim-imports | 128 MB | 10 | 317 | 973 | **1,290** | +1% | 1,315 | 73 | 0.161 |
| init-warmup | 128 MB | 10 | 304 | 975 | **1,276** | 0% | 1,330 | 70 | 0.160 |
| baseline | 256 MB | 10 | 314 | 493 | **814** | -36% | 856 | 26 | 0.204 |
| slim-imports | 256 MB | 10 | 307 | 485 | **794** | -38% | 815 | 24 | 0.199 |
| init-warmup | 256 MB | 9 | 294 | 490 | **785** | -39% | 808 | 31 | 0.197 |
| baseline | **512 MB** | 10 | 269 | 233 | **509** | **-60%** | 561 | **11** | 0.255 |
| slim-imports | 512 MB | 7 | 259 | 214 | **486** | -62% | 508 | 12 | 0.244 |
| init-warmup | 512 MB | 10 | 296 | 235 | **532** | -58% | 545 | 11 | 0.267 |

*Cold total = init + first request. Billed duration was about equal to cold total in these runs, so init is billed.*

**What the numbers say**
- **Code changes did not help.** Slimmer imports and init warm-up are within about 3% of baseline at every memory
  size, which is inside the run-to-run noise. They were measured, rejected, and not shipped.
- **Memory is the lever.** At 128 MB the function has almost no CPU, so loading and compiling the SDK dominates the
  first request. At 512 MB a cold request drops from 1.28 s to 0.51 s and a warm request from 70 ms to 11 ms.
- **Headroom.** At 128 MB the function peaked at about 102 MB (80% of the limit); 256 MB and 512 MB remove that risk.
- **Cost stays negligible.** A cold request uses more GB-s at higher memory (0.16 to 0.26), but a *warm* request, the
  common case, is cheaper: 8.8 mGB-s at 128 MB, 6.5 at 256 MB, 5.5 at 512 MB. Lambda's always-free monthly allowance
  (1 million requests and 400,000 GB-s, on both arm64 and x86, per the AWS Lambda pricing page) covers the compute
  for about 1.5 million requests even if every one were a cold start at 512 MB. Requests beyond the first million cost
  $0.20 per million, so the request count, not memory, is the limit. Initialization is billed as well, which is why cold
  requests cost more.

**Decision:** memory raised from 128 MB to **512 MB**; code unchanged.

**Limits of this measurement:** about 10 cold samples per configuration, one account and region, run on one day, and
X-Ray tracing included in the timings. Treat differences of a few percent as noise.

**Reproduce it.** The benchmark creates its own temporary function, never modifies production, and deletes the
function and its test rows on exit:

```bash
./scripts/benchmark/run.sh                       # full matrix, about 5 minutes
MEMORIES="256 512" VARIANTS="baseline" BATCHES=1 ./scripts/benchmark/run.sh   # a smaller run
```

It needs an AWS session and room for 5 parallel invocations (the account default is 10). Variants live in
[scripts/benchmark/](scripts/benchmark/README.md).

## Design decisions

- **REST API, not HTTP API.** The requirement named a REST API, which also provides request validation and
  usage controls. An HTTP API is cheaper and would suit a simpler need.
- **Lambda proxy integration** instead of VTL mapping templates, so the function owns the contract and can be
  tested without API Gateway.
- **Node.js 24, not 26.** Node.js 26 is still a Lambda public preview, so the latest generally available runtime
  was used.
- **512 MB of memory, from a benchmark.** More memory means more CPU, which cut cold starts by 60% and warm requests
  by 84%; code-level optimizations did not measurably help (see [Performance](#performance)).
- **Runtime-included AWS SDK.** This avoids an npm build step. AWS recommends bundling the SDK for strict version
  control, which is a listed follow-up.
- **ID token authorizer.** Simplest correct option for a first version. Scopes and an access-token flow would suit
  multiple resource servers.
- **Separate bootstrap stack.** Slightly more manual work, in exchange for a pipeline that cannot rewrite its own permissions.

## Not implemented

Read, list, update and delete endpoints, and per-user ownership of orders. Multiple environments, multi-region
disaster recovery, API access logs and CloudWatch alarms. Hosted sign-in with PKCE for browser clients, and
the X-Ray SDK for DynamoDB sub-segments. The first two items are the most natural next steps.

## Related

[three-tier-web-app-aws](https://github.com/bdahiya2007/three-tier-web-app-aws) is another project in this portfolio.
It uses the same OIDC, approval-gated deployment approach with CloudFormation.
