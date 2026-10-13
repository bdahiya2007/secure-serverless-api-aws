# FAQ

Questions asked about the design and the measurements, grouped by topic, with short answers and where to read more. Figures were measured on this
project (one account, one region pair, one client) unless an answer says otherwise; treat differences of a few percent as noise, and "unverified" means just that.

**Topics:** [Cognito and sign-in](#cognito-and-sign-in) | [API Gateway](#api-gateway) | [Throttling and AWS WAF](#throttling-and-aws-waf) | [Lambda](#lambda) |
[DynamoDB](#dynamodb) | [Performance and optimization](#performance-and-optimization) | [Global tables (multi-region)](#global-tables-multi-region) |
[Disaster recovery](#disaster-recovery) | [Cost and operations](#cost-and-operations) | [Security and the pipeline](#security-and-the-pipeline)

---

## Cognito and sign-in

### Why Cognito, and which plan?
Cognito user pools give hosted sign-in, token issuing and an API Gateway authorizer with no servers to run. The **Lite** plan is used: it includes social sign-in (Google), the classic hosted pages and Lambda triggers, and
Lite and Essentials share **10,000 free monthly active users per account**. The **Plus** plan has no free tier and is rejected by the module on purpose. See [runbook: Cognito](../terraform/README.md#cognito-user-pool).

### Why can users not sign themselves up?
Self sign-up is off (`allow_admin_create_user_only`), so an open sign-up page cannot be used to create accounts. Users are created by an administrator (the CLI test users) or, with the optional Google sign-in, by Cognito on a first
Google sign-in **only if the guard Lambda allows that address**.

### Which token does the API expect, and why the ID token?
The **ID token**, sent as-is in the `Authorization` header (no `Bearer` prefix). API Gateway's Cognito authorizer validates it before the Lambda runs, so unauthenticated calls never reach it. The ID token is the simplest correct choice for a
first version; an access-token flow with scopes would suit several resource servers. See the design decisions in the [README](../README.md#design-decisions).

### How long do tokens last?
ID and access tokens 60 minutes, refresh tokens 7 days (the Google consent screen in Testing mode also expires Google's own refresh tokens after 7 days). A token cannot be revoked inside its lifetime by the API alone: see the removal question below.

### Is MFA on?
It is **optional**, with app-based TOTP only (free). SMS MFA is billed and is not configured. Making it required for the pool is on the to-do list.

### Why does the CLI use `USER_PASSWORD_AUTH`?
For testing only: it lets scripts sign in without a browser. Browsers and production apps should use the **authorization code flow with PKCE**, which the separate Google client already does (it offers Google only, with no password flow and no client secret).

### How does sign-in with Google work, and who gets in?
Cognito's hosted pages send the user to Google, then issue the pool's own ID token. A **guard Lambda** (pre sign-up and pre token generation triggers) admits only allow-listed addresses, checked on **every sign-in and refresh**; it fails closed, gives no reason, and never logs an
email. Without the guard any Google account could sign in, so Terraform refuses the switch without it. See [runbook](../terraform/README.md#sign-in-with-google-optional-off-by-default) and [COGNITO_TESTING_RUNBOOK.md](COGNITO_TESTING_RUNBOOK.md).

### What happens if I remove someone from the allow-list?
New tokens and refreshes are **refused** (verified), even for a user who already has a profile, because the guard runs on every token. A token issued **before** the removal still works until it expires (up to 60 minutes): ID tokens are stateless.
For an immediate cut-off also run `aws cognito-idp admin-user-global-sign-out` and `admin-disable-user`, or shorten the token lifetime.

### Can a token from one region's pool be used in the other region?
With multi-region and Google sign-in both on, each region has its own pool and **both APIs trust both pools**. Verified: all four combinations (each pool's token on each API) were accepted. With multi-region alone there is one pool in us-east-1 that both APIs trust.
Two separate pools do not share users, which is why Google (an external identity provider) is used: nothing has to be copied. Cognito's own multi-Region replication would share them; see the next question.

### The deploy failed with AccessDenied on DescribeUserPoolDomain. What happened?
The pipeline's deploy role lacked `cognito-idp:DescribeUserPoolDomain`, which cannot be limited to a user pool and so needs `*`. The first apply created the domain but could not wait for it, leaving it **tainted** in the state. Fix: apply the bootstrap (the permission was added), untaint the domain, and re-run the deploy.
It never showed up in the Google demo because that was applied locally with broader permissions; a feature that moves from a local apply to the pipeline needs its resource types checked against the deploy role.

### Does a browser app need Google to sign in?
No. With `cognito_domain_prefix` and `browser_callback_urls` set, Cognito's **hosted sign-in pages** sign users in with a username and password, using the **authorization code flow with PKCE**; no Google account, no client secret, and no cost on the Lite plan. Users are still created by an administrator (no self sign-up).
Google stays an optional extra with its own client. See [runbook](../terraform/README.md#hosted-sign-in-for-a-browser-front-end-optional-off-by-default).

### Why the authorization code flow with PKCE, and not the implicit flow or a password form in the app?
The app never sees the password: the user types it on Cognito's pages. The code is single-use and bound to a secret the app generated (the PKCE verifier), so a code intercepted in the redirect is useless without it. The implicit flow (tokens in the redirect URL) is deprecated and is not enabled on the browser client.

### Does Cognito have built-in multi-Region replication, and why is it not used here?
Yes: [multi-Region replication (MRR)](https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-multi-region.html) creates a **replica user pool** in a second region that shares the primary's user directory and user pool ID, and can fail over managed login, federation and
direct API calls using a Route 53 health check on the pool's domain. It was **not used** because of its requirements and limits (from the AWS page):

| | Multi-Region replication | This project's pool-per-region with Google |
|---|---|---|
| Plan | **Essentials or Plus**, not Lite | Lite (free) |
| Extra needs | A **multi-Region customer managed KMS key**, and separate add-on costs (KMS keys bill monthly; amounts unverified) | None |
| Users | One shared directory | Separate pools; Google is the single source of identity |
| New users in the second region | **Not possible** (the secondary cannot create users); a federated user can use the secondary only if they **signed in to the primary before** | A first Google sign-in creates the user in either region, if the guard allows |
| MFA | TOTP is **not supported** in the secondary | TOTP optional in each pool |
| Failover | Automatic, from a Route 53 health check on the pool's domain | Clients (or Route 53 on the API) choose a region; sign-in itself is not auto-failed-over |
| Per-user identity | Shared directory, so the user is the same across regions (expected; **not tested here**) | A different Cognito `sub` per pool, so ownership must key on the Google identity |

It would be the better production choice for password or admin-created users and for automatic sign-in failover, if the plan and cost are acceptable. **Not evaluated here:** whether the Terraform provider can manage replicas, how API Gateway's authorizer treats a replica's ARN,
and the exact cost. It is on the to-do list.

### Why does the same person have two different Cognito IDs?
With two separate pools (this project's setup) each pool assigns its own `sub`, so when per-user ownership of orders is built it must key on the Google email or Google subject, not Cognito's `sub`, or one person would look like two. (Cognito's multi-Region replication shares one directory, which should avoid this; not tested here.)

### I got 404 when testing a token. Is that a failure?
No: **404 means the token was accepted** and the order does not exist. A **401** is the refusal (no token, a garbage token, an expired one, or a token from a pool the API does not trust).

---

## API Gateway

### Why a REST API and not an HTTP API?
The requirement named a REST API, which also provides request validation and usage controls. An HTTP API is cheaper and would suit a simpler need; it is listed as not evaluated in the [optimization guide](OPTIMIZATION_GUIDE.md#8-not-evaluated).

### Why validate the request in API Gateway and again in the Lambda?
Defense in depth. The API validates the body against a JSON Schema and rejects malformed requests **before the Lambda is invoked or billed**; the Lambda validates again with an allow-list of fields, so a direct invocation or a future route cannot skip the check. Error bodies never echo the input.

### Why does one read bypass Lambda entirely?
`GET /orders/{orderId}` uses a **direct DynamoDB integration**: API Gateway calls DynamoDB itself with a read-only role, using request and response mapping templates (VTL). The same read also exists as a Lambda (`GET /orders-via-lambda/{orderId}`) so the two can be compared like for like.

### Which read is better?
Measured: the **Lambda read was about 30 to 40 ms faster** at the median; the **direct read is about $0.25 per million requests cheaper**, has no Lambda cold start, and has less to run. The Lambda read also validates ids, flags truncation, and leaves logs and traces. Choose the Lambda when latency, observability or logic matter,
the direct integration when the read is pure mapping. Why the direct one is slower is an informed guess, not a measurement. See [optimization guide §3.3](OPTIMIZATION_GUIDE.md#33-direct-read-against-lambda-read-like-for-like).

### What are the drawbacks of the direct integration?
VTL templates have no unit tests (they are verified end to end), results are cut off at 100 items **silently** (the Lambda read has a `truncated` flag), reads leave no Lambda logs or X-Ray traces, a bad id is just a lookup (404, not 400), and the response shape is coupled to DynamoDB's typed JSON.

### What does the stage cache do, and is it worth it?
An optional cache (300 s TTL, keyed by the order id, encrypted) answers repeated `GET`s without calling the backend. Measured: about **6 to 7% faster** on repeated reads of one order; reads can be **stale for up to 300 s** after a write; 404s are cached; a flush takes about 50 s; responses are shared between signed-in users. It bills by the hour, so it is off by default.
See [runbook](../terraform/README.md#api-gateway-stage-cache-optional-billed-off-by-default).

### What do the status codes mean?

| Code | Meaning |
|---|---|
| `200` / `201` | Read OK / order item saved |
| `400` | Invalid body, or (Lambda read) an invalid id |
| `401` | Missing, invalid or expired token |
| `403` | `Missing Authentication Token`: **no such route and method** (not a token problem); or a WAF block |
| `404` | No such order (or an accepted token with nothing to read) |
| `409` | That order item already exists (writes never overwrite) |
| `429` | The throttle on that method |
| `500` | Internal error, or the Lambda was throttled (account concurrency limit) |

### Why does `GET /` or `GET /orders` say "Missing Authentication Token"?
There is no route there: `/orders` accepts only `POST`, and `/` has none. API Gateway answers `403 Missing Authentication Token` for any undefined route and method. Working paths are `/health` (multi-region only), `POST /orders`, `GET /orders/{id}` and `GET /orders-via-lambda/{id}`.

### How does CORS work here, and is it a security control?
It is **off by default**. With `cors_allowed_origins` set, a browser front end at a listed origin can call the API: each route answers the browser's preflight `OPTIONS` request (a MOCK integration, no backend call), the Lambdas and the direct-read templates echo an allowed `Origin`
on every response, and gateway responses add the header for the **first** listed origin for errors API Gateway produces itself (such as 401). Only exact origins are accepted, never `*`. **CORS is not authentication:** it only tells browsers which sites may read responses; every route still needs a valid token, and non-browser clients ignore it.
See [runbook: CORS](../terraform/README.md#cors-for-a-browser-front-end-optional-off-by-default).

### Are there API access logs?
Not enabled: they need an account-wide API Gateway CloudWatch role and have a small cost, so it needs a decision first. Writes leave Lambda logs and X-Ray traces; direct reads leave neither. See the roadmap in the [README](../README.md#known-limitations-and-roadmap).

---

## Throttling and AWS WAF

### Why use AWS WAF for rate limiting instead of the API Gateway rate-limiting feature?

**It is both, not instead of.** They do different jobs.

| | API Gateway throttling (always on) | AWS WAF rate rule (optional, off by default) |
|---|---|---|
| Setting | 5 requests per second, burst 10, **per method** | 100 requests per 5 minutes **per client IP** |
| Cost | Free | About $6 a month (web ACL $5 plus rule $1, billed hourly even when idle, plus $0.60 per million requests) |
| When exceeded | `429` | `403`, and the IP stays blocked for a while |
| Where it runs | Inside API Gateway | In front of API Gateway, so blocked requests never reach the authorizer, the cache or the Lambda |

Why the API Gateway limit alone is not enough:

- **It is not per client.** Every caller of a method draws from the same bucket, so one noisy or hostile client can use it up and cause `429`s for everyone else on that method.
- **It does not limit unauthenticated floods.** In a test, 200 rapid requests with no token all got `401` and none got `429`: they were rejected before the throttle counted them. (Whether API Gateway bills those requests was not verified.)
- **The other API Gateway option, usage plans with API keys,** limits per key, not per IP. It needs keys issued and managed, and a caller without a key is only limited by the shared bucket. Keys are also not an authentication control. They are not used here.

What was measured for the WAF rule:

- A burst of 300 requests from one IP got 231 through before the first `403`, not 100: WAF rate rules are enforced on a delayed window, so the limit is approximate.
- The IP then stayed blocked for about 5 minutes, and **valid requests from that IP were blocked too**. People behind one shared IP (an office, a mobile gateway) share one budget.

It is a switch (`enable_waf`) because it bills by the hour. The always-on layer is the free throttle; the WAF is the per-IP layer to turn on for real traffic.

More: [runbook, WAF section](../terraform/README.md#waf-rate-limit-optional-billed-off-by-default), [DEMO_RESULTS.md](DEMO_RESULTS.md) (phase 3).

### Where does the "shared bucket" in API Gateway throttling come from?

From API Gateway's **token bucket** throttling, configured here with `aws_api_gateway_method_settings` and `method_path = "*/*"`
(`terraform/modules/rest-api/main.tf`): rate 5, burst 10.

- Tokens are added at the **rate** (5 per second) up to the **burst** (the bucket size, 10). Each request takes a token; a request that finds none gets `429`.
- The `*/*` setting is a default for **every method**, and AWS applies per-stage limits **at the method level**: **each method has its own bucket**.
  Measured: with a valid token, 200 rapid requests to one method got 10 through then 171 `429`, while a trickle of about 3 requests per second to a **different** method at the same moment was untouched (15 of 15 accepted).
- **"Shared" means shared between callers.** The bucket is not keyed by who is calling, so everyone using that method draws from the same tokens. API Gateway separates clients only with usage plans and API keys, which this project does not use.

A correction worth knowing about: earlier versions of the docs called this limit "stage-wide" and gave a worst-case abuse cost of about $45 a month. It is per method, so with three data routes the ceiling is
15 requests per second, about 39 million requests, **about $136 a month** (plus backend cost). That is fixed in the optimization guide.

A related limit: the **account's Lambda concurrency limit is 10** here, so about ten or more parallel requests to a Lambda-backed route get `500` from the proxy (the Lambda `Throttles` metric rises; the function itself has no errors).

Source: [AWS: throttle requests to your REST APIs](https://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-request-throttling.html).
More: [OPTIMIZATION_GUIDE.md](OPTIMIZATION_GUIDE.md) (worst-case abuse), [runbook](../terraform/README.md#waf-rate-limit-optional-billed-off-by-default).

### Why is the WAF off by default?
It bills **by the hour even when idle** (about $0.008 an hour, about $6 a month, plus request charges) with no free tier. It is applied for a short demo and removed; a push to `main` also removes it, because the deploy applies with every switch off.

### Does the WAF see requests that the cache would answer?
Yes: it sits in front of API Gateway, so it evaluates a request before the authorizer, the cache and the Lambda. Blocked requests cost nothing downstream.

### Can the WAF limit per user instead of per IP?
The rule built here is per IP. Rate-based rules can aggregate on other keys (for example a header), but that is not built or tested here. A limit per **user** is better served by identifying the user first (a usage plan, or an application check), which would come with the per-user ownership work.

### How do I test the throttle and the WAF?
For the WAF: apply `enable_waf=true`, run `scripts/demo/waf-checks.sh` (300 unauthenticated requests; expect `401` then `403`), wait about 5 minutes for the block to clear, then switch it off. For the throttle: send rapid requests with a valid token to one method and watch for `429`. The method and the results are in [DEMO_RESULTS.md](DEMO_RESULTS.md) and the [runbook](../terraform/README.md#waf-rate-limit-optional-billed-off-by-default).

---

## Lambda

### Which Lambda functions are there?
`save-order` (the write), `save-order-lookup` (the Lambda read), and, only with Google sign-in, `save-order-signin-guard`. With multi-region on, `...-dr` copies of each run in the second region (IAM names are global, hence the suffix).

### Why Node.js 24 and not 26?
Node.js 24 is the latest **generally available** Lambda runtime (supported until April 2028); Node.js 26 was still in public preview.

### Why arm64?
Graviton is cheaper per millisecond than x86, and the free tier covers both. It is the module's default.

### Why 512 MB?
From a benchmark: memory is the lever because CPU scales with it. At 128 MB a cold request took 1.28 s and a warm one 70 ms; at 512 MB they took 0.51 s and 11 ms. Cost stays negligible and a warm request is cheaper at higher memory. Code-level changes (slimmer imports, init warm-up) did **not** help beyond noise. See [README: Performance](../README.md#performance).

### Why initialize clients outside the handler?
The DynamoDB client and the table name are created once per execution environment, not per request. Only the client and configuration live at module level: **request data and the caller's identity stay inside the handler**, so nothing leaks between requests.

### Why use the runtime's built-in AWS SDK?
It avoids an npm build step and supply-chain exposure; the package is **2,089 bytes zipped**. AWS recommends bundling for strict version control, which is a listed follow-up (esbuild bundling is not evaluated). The DAX package (optional) is the exception, built from a committed lockfile.

### How do the Lambdas stay least-privilege?
The write role can `PutItem` on one table ARN and write to its own log group; the read role can `Query` one table. The module **rejects wildcard actions and resources at plan time** (X-Ray write actions are the one documented exception), and every role carries the pipeline's **permissions boundary**, which caps it at logging, X-Ray writes and Orders table data access.

### How are duplicate or overwriting writes prevented?
A condition expression (`attribute_not_exists` on the order and item ids) makes an existing item return `409` instead of being replaced.

### What do the logs and traces contain?
Structured JSON logs with 14-day retention (bounded to keep storage inside the free tier) and X-Ray active tracing on the functions. 500 responses are generic and logs record the error type and request id, **never order contents**, and the guard logs only its decision and trigger, never an email.

### What happens under heavy parallel load?
This account's **Lambda concurrency limit is 10**. Measured: parallel requests beyond that to a Lambda-backed route returned `500` (the Lambda `Throttles` metric rose; no function errors). A higher limit needs a quota request.

---

## DynamoDB

### Why on-demand capacity?
No capacity to provision and an idle cost of effectively zero. It suits a learning project with spiky, tiny traffic; at a steady high volume provisioned capacity could be cheaper.

### What is the key design?
Partition key `orderId`, sort key `itemId`: one item per call, and an order is all the items under its `orderId`. A read is a `Query` on the order id (up to 100 items). The API never does a `Scan` (unbounded, and it would expose every order), so there is no "list all orders".

### Why strongly consistent reads, and what is the catch?
So a client reads back what it just wrote (read-your-writes). The catch: a strongly consistent read uses twice the read units of an eventually consistent one, **DAX cannot cache it**, and across regions it only applies **inside one region**.

### Why is there a 100-item limit, and what is `truncated`?
One `Query` returns at most 100 items. The Lambda read reports `"truncated": true` when the cap cut the list off; the **direct read cuts off silently**. Pagination would need a continuation token in the API (on the roadmap).

### Is the table encrypted, protected and backed up?
Encrypted at rest with the AWS-owned key (free; a customer-managed key has a monthly fee and is not used). **Deletion protection is on.** **Point-in-time recovery is off** (billed per GB), so there is **no backup**; a global table replicates a bad write or delete to both regions, so turn it on before real data matters.

### Why are DynamoDB Streams on?
They are free to enable and a global table requires them (`NEW_AND_OLD_IMAGES`). Nothing reads the stream yet.

### Why did DAX not help?
The function itself takes about 6 ms inside a roughly 320 ms request that is mostly network, so there was nothing to save. Measured: the Lambda read median was 322 ms with and without DAX, the cold start grew from about 0.58 s to 2.2 s (a VPC and a DAX connection), and reads were stale or cached-empty for the 60 s TTL. It is built but off by default. See [DEMO_RESULTS.md](DEMO_RESULTS.md).

---

## Performance and optimization

### Why is a request about 300 ms when the function takes 6 ms?
Most of it is network and TLS from the test client: an unauthenticated request that API Gateway rejects with `401` (no backend at all) already takes about 273 ms. The Lambda adds about 30 to 50 ms over that floor and the direct integration about 60 to 80 ms. A client in the same region would see far less. New connections per request make the absolute numbers higher; compare paths with each other.

### Is the Lambda read really faster than the direct read?
Yes, in every run: about 30 to 40 ms at the median over interleaved rounds (so network drift hits both equally), with a better p90 and worst case. Why is unproven; the likely reasons are API Gateway signing the DynamoDB request and rendering the templates, against a warm Lambda keeping a connection open.

### How is the Lambda cold-start time in the performance table measured?

From **Lambda's own `REPORT` log line**, not from client-side timing. `scripts/benchmark/run.sh`:

1. Creates a **temporary copy** of the function (same role, runtime, arm64 and X-Ray tracing) so production is never touched.
2. **Forces cold starts** by changing the function's environment variable before each batch, which makes Lambda create new execution environments.
3. Fires **5 parallel invocations** per batch with `--log-type Tail` and reads the `REPORT` line from the log tail.
4. Counts a sample as **cold only if its report has an `Init Duration`**; otherwise it is warm. This guards against a late request in a parallel burst landing on an already-warm environment.
5. Reports **cold total = Init Duration + the first request's Duration**. For example at 128 MB: 308 ms init + 983 ms first request = 1,281 ms; at 512 MB: 269 ms + 233 ms = 509 ms. The billed duration was about equal to the cold total, so initialization is billed.

The matrix was 3 code variants x 3 memory sizes, about 10 cold samples per configuration, every request a real DynamoDB write, and the table shows **medians** (86 cold and 49 warm samples in all).

What it does **not** include: API Gateway time, TLS and network. This is the time Lambda spends, not the end-to-end latency; the roughly 300 ms request times elsewhere in the docs are a different, client-side measurement.

Limits: about 10 samples per configuration, one account, region and day, with X-Ray tracing included in the timings. Differences of a few percent are noise, so the finding that code changes did not help (within about 3%) is inside it;
the finding that memory matters (cold start 1.28 s to 0.51 s) is far larger.

More: [README, Performance](../README.md#performance), [scripts/benchmark/](../scripts/benchmark/README.md), [OPTIMIZATION_GUIDE.md](OPTIMIZATION_GUIDE.md).

### Why report the median and p90, and why interleave requests?
The median is the typical request; the **p90** shows the slow tail (one request in ten is slower). Requests to the compared paths are **interleaved** (direct, Lambda, gateway floor, repeat) so network drift affects each path equally.

### How do I reduce cold starts?
Raise memory (done: 512 MB). **Provisioned concurrency** would remove them but costs about $5.40 a month per 512 MB environment even when idle, and was not evaluated. Putting the function in a VPC (as DAX needs) makes cold starts worse. With steady traffic cold starts are rare.

### Which optimizations did not help?
Slim imports and init warm-up (within about 3% of baseline, noise), DAX (no gain), and both caches together (within noise of the cache alone). They were measured, rejected or left off, and documented, which was the point.

---

## Global tables (multi-region)

### What is built?
With `enable_multi_region` on, `Orders` becomes a **DynamoDB global table** with a writable replica in `us-west-2`, a second copy of the API (Lambda and API Gateway) runs there, and Route 53 sends each client to the nearest healthy region at one name. It is off by default, applied locally for a short demo and removed. See [runbook](../terraform/README.md#multi-region-activeactive-global-table-optional-billed-off-by-default).

### What does it cost?
Every write is **billed again in the replica region** (replicated write units) plus storage there, the second stack adds its own request charges, and each Route 53 health check is a monthly charge with no free tier (roughly $1 to $2 each; **unverified**). A 30 minute demo was estimated at a few cents; the stack running idle is a few dollars a month (mostly the health checks).

### How fast is replication?
Measured 0.3 to 1.2 s in both directions (median about 0.8 s through the API); CloudWatch `ReplicationLatency` averaged 569 ms with a maximum of 903 ms. It is asynchronous, so there is no hard guarantee.

### What if both regions write the same item at once?
**Last writer wins**: tested with the same item written in both regions at the same moment (quantity 10 and 20); both regions converged to 20 and the other write was lost silently. Orders are keyed by order and item, so a conflict needs the same item written in both regions together; counters and balances would need a different design.

### Can I read my write from the other region immediately?
Not guaranteed. Strongly consistent reads apply only inside the region that took the write; the other region may take a second. Do not read-after-write across regions.

### Is a global table a backup?
No. A bad write or delete replicates to both regions within seconds. Use point-in-time recovery (off, billed) for undo.

### Why is the replica not deletion protected, and why is it applied locally?
So that switching the feature off can remove it (the primary table keeps its protection). The deploy role deliberately has no second-region, Route 53 or ACM access, so the stack is applied locally and `deploy.yml` stops with a message if it is still in the state. A push to `main` applies with the switch off.

### Why do global tables need streams?
DynamoDB replicates through the table's stream, which must be on with both the old and new image of each item. Enabling streams is free.

---

## Disaster recovery

### What recovery time and data loss should I expect?
Roughly **under 2 seconds of writes** at risk (replication lag was 0.3 to 1.2 s; an unreplicated write in a failed region can be lost) and about **1.5 to 3 minutes** to serve again from the other region for a real failure: three failed 30 s health checks (about 90 s) plus up to 60 s of DNS caching. One demo, one failure type; order of magnitude, not a guarantee. See [DISASTER_RECOVERY.md](DISASTER_RECOVERY.md).

### How does failover work?
Route 53 holds two latency-based alias records for one name, each with a health check on that region's `GET /health`. A region whose check fails is dropped from the answers; clients move after the DNS answer (60 s TTL) expires. Each region has its own custom domain and free ACM certificate.

### Why did the failover test show 31 seconds when you say 1.5 to 3 minutes?
The test **forced** the answering region's health check to fail (inverting it), which changes its status at once and so skips the detection time. A real failure still needs the three failed checks. The 31 s is the DNS-side portion, not a recovery time.

### What failures are not covered?
- **DynamoDB or Lambda broken but API Gateway up:** the health route is shallow (a fixed answer from API Gateway), so Route 53 does not notice. It needs a deeper check or a manual failover.
- **A bad deploy or a bad write to both regions**, and accidental deletes (replicated; no backup).
- **Cognito down in us-east-1 without the Google two-pool setup.**
- Route 53 or the DNS name itself, and the Terraform state or pipeline (applied locally).

### Can I fail over by hand?
Yes: force the health check of the region to drain with `aws route53 update-health-check --inverted`, confirm with `GET /health` (it names the answering region), and set `--no-inverted` to fail back. Steps in [DISASTER_RECOVERY.md](DISASTER_RECOVERY.md#manual-failover-and-failback).

### Is sign-in covered in a disaster?
With Google sign-in and multi-region both on, each region has its own pool and guard and both APIs trust both pools: **verified working, not tested during a real Cognito outage**. Without Google sign-in, sign-in depends on the us-east-1 pool, and tokens already issued keep working in the other region until they expire (about an hour).

### How do I test it, and how often?
Run `scripts/demo/multi-region-checks.sh` (replication, conflict, domain) and, with `SIMULATE_FAILOVER=1`, a forced failover; the checks are restored on exit. A real disaster test (breaking a Lambda in one region) has **not** been done and is on the to-do list. Repeat after any routing, API or table change and every few months. See [TESTING.md](TESTING.md#7-multi-region-activeactive-optional-billed).

### Do I need a domain name?
For the Route 53 layer, yes: an existing public hosted zone and a name inside it. Terraform adds only new records for that name and the certificate validation; existing records are never changed.

---

## Front end hosting

### Why is the front end a separate Terraform stack?
The pipeline applies the dev stack on every merge with its optional switches off, and its deploy role has no CloudFront, certificate or DNS permissions (by design). A separate root with its **own state** (`frontend/terraform.tfstate`, outside the `dev/` prefix the deploy role can touch) is applied locally and left on: a merge can never remove it, and a front-end change cannot disturb the API stack. It reads the dev stack's public outputs to build `config.json`.

### Can adding the front end affect the existing static website?
It is built not to: the module only adds new resources (a new bucket, distribution, dedicated certificate, response-headers policy, alarm and two DNS records) and never references the existing site's distribution, web ACL, buckets, certificate or records; the DNS records cannot overwrite an existing name. `scripts/demo/static-site-snapshot.sh save` and `compare` prove it by fingerprinting the existing site before and after (distribution configuration, web ACL, bucket policies, and every DNS record).

### Why a dedicated certificate and not the existing wildcard?
It keeps the two sites independent: a shared certificate would stop either project from deleting or replacing it while the other uses it. A certificate for one name is free, and costs one extra validation record.

### What does the Content Security Policy allow?
Only the page itself for scripts, styles, images and fonts; and for network calls only itself, the API and the Cognito hosted domain (so a script that is somehow injected cannot send data elsewhere). There is no inline script or style, no framing, and no `unsafe-inline` or `unsafe-eval`. The page therefore ships its JavaScript and CSS as separate files.

### Is the front end protected by a WAF?
Not by default. A web ACL on CloudFront (`enable_waf` in the front-end stack, about $6 a month) would protect only the delivery of the static files, **not the API**, which has its own switch. Without it the front end still has TLS 1.3, security headers, a private bucket and AWS's automatic network-level DDoS protection for CloudFront; a free alarm warns of a request flood.

## Cost and operations

### What costs money by default?
Almost nothing: DynamoDB is on-demand, Lambda and Cognito Lite are inside their free tiers, and the dashboard uses free AWS-published data. REST API requests (about $3.50 per million) are the main usage cost. Everything that bills by the hour (WAF, API cache, DAX, multi-region) is **off by default** and applied only for a short demo.

### How do I make sure nothing billable is left on?
`terraform output` must show `waf_enabled`, `api_cache_enabled`, `dax_enabled`, `multi_region_enabled` and `federated_signin_enabled` all `false`. Also check there are no DAX clusters, replicas, health checks or web ACLs. A scheduled check for this is on the to-do list. The verification commands are in the [runbook](../terraform/README.md#usage) and [COGNITO_TESTING_RUNBOOK.md](COGNITO_TESTING_RUNBOOK.md#8-switch-off-verify-and-clean-up).

### Why do the optional features run from a laptop, and what is the "switch set" gotcha?
The pipeline's deploy role has no DAX, second-region, Route 53 or ACM permissions, so the demos are applied locally. **Every apply replaces the whole set of switches**, so repeat each switch you want to keep or Terraform removes it; a plain `terraform apply` turns them all off.

### What did the demos cost?
Estimated from list prices (the bill was not read): the cache, DAX and WAF demos about $0.10 to $0.15 in total, the two-region Cognito test a few cents, and Google sign-in alone nothing. Rates while on: DAX about $0.05 an hour, the cache about $0.02, the WAF about $0.008, and the multi-region stack mostly its two health checks (roughly $3 a month, unverified), plus request and replicated-write charges. All three of DAX, cache and WAF on together is about $0.07 an hour. See [DEMO_RESULTS.md](DEMO_RESULTS.md).

### Where do I see the real bill?
The AWS Billing console (Cost Explorer UI is free to use; the Cost Explorer API costs $0.01 a call). Billing data lags by up to about a day, and a $5 budget alert exists.

---

## Security and the pipeline

### How does CI deploy without AWS keys?
GitHub OIDC with short-lived tokens, no stored keys. The trust policy pins the repository by immutable ID and allows only `main` (plan) and the `production` environment (apply), which needs manual approval. Pull requests cannot assume the role.

### Why is the bootstrap a separate stack?
So the pipeline cannot rewrite its own permissions: the deploy role, the permissions boundary and the state bucket live in a manually applied stack, with explicit denies against editing the role or removing the boundary.

### What is the permissions boundary?
A policy attached to every role the pipeline creates. It caps those roles at logging, X-Ray writes and Orders table data access (and, for the optional features, VPC networking, DAX reads and the second region's table and log groups), so even an over-broad inline policy yields no more.

### How are secrets and personal data kept out of GitHub?
A scanner runs as a pre-commit hook and in CI on every pull request: credentials, AWS identifiers, personal data, state and key files, and now **Google credentials and real Cognito hosted domains**. Secrets (the Google client secret) and personal data (the allowed emails) exist only as shell variables at apply time. They are stored in the Terraform state (private, encrypted bucket), nowhere else. See [SECRET_SCANNING.md](SECRET_SCANNING.md).

### What does the scanner not catch?
Domain names, Route 53 zone IDs, Cognito app client IDs and a bare hosted-domain prefix have no recognisable shape; put them in the private block list.

### Why are some pull requests without the "Generated with Claude Code" footer?
That was an explicit instruction for this repository: PR descriptions carry no such footer (the commit trailer remains). PRs #1 to #10 predate it and still contain it.
