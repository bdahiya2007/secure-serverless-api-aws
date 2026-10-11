# FAQ

Questions asked about the design and the measurements, with short answers and where to read more. Figures were measured on this project
(one account, one region pair, one client) unless an answer says otherwise; treat differences of a few percent as noise.

- [Why use AWS WAF for rate limiting instead of the API Gateway rate-limiting feature?](#why-use-aws-waf-for-rate-limiting-instead-of-the-api-gateway-rate-limiting-feature)
- [Where does the "shared bucket" in API Gateway throttling come from?](#where-does-the-shared-bucket-in-api-gateway-throttling-come-from)
- [How is the Lambda cold-start time in the performance table measured?](#how-is-the-lambda-cold-start-time-in-the-performance-table-measured)

## Why use AWS WAF for rate limiting instead of the API Gateway rate-limiting feature?

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

## Where does the "shared bucket" in API Gateway throttling come from?

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

## How is the Lambda cold-start time in the performance table measured?

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
