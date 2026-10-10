# Optimization guide: when, why, and what it costs

How the Lambda and the API were tuned, **when each technique is worth using**, and what it costs in latency, money
and security. Everything here was measured on this project unless it says "not measured".

- Measured in October 2026 in `us-east-1`, from one client, on a personal AWS account.
- Prices were checked against the AWS pricing pages in the same month. Prices change; re-check before relying on them.

## Summary

| Question | Answer from this project |
|---|---|
| Is the package too big? | No: **2,089 bytes** zipped. The SDK comes from the runtime and tests are excluded. |
| Is initialization in the right place? | Yes: the client and config are created once per environment, outside the handler. |
| What was actually slow? | A **cold request: about 1.28 s** at 128 MB (init 308 ms plus a 983 ms first request). Warm: about 70 ms. |
| What fixed it? | **Memory (CPU)**: 512 MB gives about 0.51 s cold and 11 ms warm. Code-level tuning did nothing measurable. |
| Is the direct DynamoDB read faster? | **Not in our measurement.** It removes the Lambda (a cold-start source and a cost), but it was about as fast as the Lambda path, not faster. |
| Where does the money go? | **API Gateway: about $3.50 per million requests**, about 80 to 96% of the cost of any request. Lambda tuning saves cents. |

## 1. Cold and warm requests

Every optimization targets one of two situations:

- **Cold request:** a new execution environment is created. You pay *init* (load code and libraries) plus the first request.
- **Warm request:** an existing environment is reused. Only the handler runs.

How often a request is cold depends on traffic. Low or bursty traffic means mostly cold. Steady traffic means mostly warm.
Environments are reused for minutes, then retired.

## 2. When to use each technique

| Technique | Why it helps | Use it when | Skip it when | Result here |
|---|---|---|---|---|
| **Initialize outside the handler** (clients, config, compiled patterns) | Runs once per environment, not per request. Init also gets extra CPU. | **Always** | Never; only per-request values stay inside | Already done |
| **Shrink the package** | Less to download and unpack | The package is large (bundled dependencies, tens of MB) | It is already tiny | 2 KB; nothing to gain |
| **Raise memory** | CPU scales with memory; JavaScript parsing and SDK loading are CPU-bound | Cold starts or duration are slow, or memory is near its limit. **Measure first.** | The function is I/O-bound and already fast | **Cold 1.28 s to 0.51 s, warm 70 to 11 ms** |
| **Slim SDK imports** | Fewer modules to load | Init is dominated by library loading and CPU is not the limit | Memory is the bottleneck (our case) | No measurable gain; rejected |
| **Init warm-up and client timeouts** | Moves credential/region resolution into the boosted-CPU init phase; fails fast on hangs | Slow first-request work that can move earlier, or hangs are costly | The gain is inside the noise | No gain; rejected |
| **Bundle and minify** (esbuild) | One small file, pinned SDK, often faster cold start | You need a pinned SDK or have many dependencies | You want no build tooling | **Not measured**; runtime SDK chosen on purpose |
| **Provisioned concurrency** | No cold starts: environments stay initialized | A strict latency target with steady traffic | Cost matters (it bills continuously, even when idle) | **Not used or measured** |
| **Direct service integration** | One fewer service in the path; no function to run or pay for | The request is pure data mapping (key lookup, simple query) | You need validation, rules, branching or complex logic | Used for the read path |

## 3. Measurements

### 3.1 Memory and code variants (cold start benchmark)

Method: a temporary copy of the function (same role, runtime, arm64, X-Ray), 3 code variants x 3 memory sizes, about 10
forced cold starts and 5 warm requests each (135 invocations), every request a real DynamoDB write. Timings come from
Lambda's `REPORT` line. Full matrix and method: [Performance in the root README](../README.md#performance). Reproduce it with
`./scripts/benchmark/run.sh`.

| Configuration | Cold total (init + first request) | Warm request | GB-s per cold request |
|---|---|---|---|
| Current code, 128 MB (before) | 1,281 ms | 70 ms | 0.160 |
| Current code, 256 MB | 814 ms (-36%) | 26 ms | 0.204 |
| **Current code, 512 MB (chosen)** | **509 ms (-60%)** | **11 ms (-84%)** | 0.255 |
| Slim imports / init warm-up, any memory | within 3% of the same memory's baseline | | |

### 3.2 End-to-end request latency

Method: 30 requests per path from one client (WSL on a home network) to the deployed API, with a **new TCP and TLS
connection per request**, timing the total request. The function was warm.

| Path | Median | p90 | Min | Max |
|---|---|---|---|---|
| API Gateway only (unauthenticated `GET`, rejected with 401, no backend) | 274 ms | 285 ms | 262 ms | 369 ms |
| `GET /orders/{id}`: direct DynamoDB integration (no Lambda) | 353 ms | 374 ms | 276 ms | 407 ms |
| `POST /orders`: Lambda (512 MB) plus DynamoDB write | 327 ms | 339 ms | 303 ms | 538 ms |

**How to read it**
- **The network dominates.** The 401 row (no backend work at all) is already 274 ms, mostly the round trip, TCP and TLS setup.
  What each backend adds on top is small: about **+79 ms** for the direct read and **+53 ms** for the Lambda write.
- **The direct read was not faster.** The two paths do different work (a strongly consistent `Query` plus template
  processing, against a `PutItem`), so this is not a like-for-like comparison. What it does show is that **removing the Lambda
  did not buy lower latency here**. An earlier version of the README claimed "lower latency"; that claim was unmeasured and
  has been corrected.
- **The real advantages of the direct read** are no Lambda cold start, no function to run, patch or pay for, and fewer moving parts.
- Not measured: a Lambda-based read of the same data, a client in the same region, and cold-start behaviour of the direct read
  (it has none of Lambda's, but API Gateway itself can add a small first-request cost).

**Caveats:** one client, 30 samples, one day, a new connection per request, internet path. Differences of a few percent are noise.

To repeat it, sign in as in [TESTING.md](TESTING.md) and time requests with `curl -w '%{time_total}\n'`.

## 4. Cost

Prices checked October 2026, `us-east-1`: API Gateway REST **$3.50 per million requests** (the free tier is for new
accounts only, so it does not apply here); DynamoDB on-demand **$0.625 per million writes and $0.125 per million reads**
(a strongly consistent read of up to 4 KB uses 1 read unit, an eventually consistent one 0.5); Lambda arm64
**$0.0000133334 per GB-second** and **$0.20 per million requests**, with an always-free **1 million requests and
400,000 GB-seconds per month**; provisioned concurrency $0.0000041667 per GB-second.

### Cost per million requests (outside the free tiers; computed)

| Path | API Gateway | DynamoDB | Lambda | About |
|---|---|---|---|---|
| Write via Lambda, warm, 512 MB (about 11 ms billed) | $3.50 | $0.625 | $0.27 | **$4.40** |
| Read, direct integration (strongly consistent, small order) | $3.50 | $0.125 | none | **$3.63** |
| The same read via a Lambda (hypothetical) | $3.50 | $0.125 | $0.27 | $3.90 |
| Read, direct, eventually consistent (hypothetical) | $3.50 | $0.0625 | none | $3.56 |

- **The direct read saves about $0.27 per million (about 7%)**. Strong consistency costs about $0.06 per million extra.
  Both are small next to API Gateway's $3.50.
- **Lambda tuning moves cents.** At learning volumes (for example 10,000 requests a month) the whole API costs a few cents.

### Cost of the memory change (Lambda compute only, per million requests)

| | 128 MB | 512 MB |
|---|---|---|
| All warm requests | $0.12 | **$0.07** (cheaper) |
| All cold requests | $2.14 | $3.39 (+59%) |

Higher memory makes **warm** requests cheaper (they finish much faster) and **cold** requests dearer. Init is billed. At
512 MB the free compute allowance (400,000 GB-s) covers about 1.5 million all-cold requests, but the 1 million request
allowance is reached first.

### Other options (computed)

- **Provisioned concurrency**, one always-warm 512 MB environment: **about $5.40 per month**, billed whether or not
  anyone calls the API, plus normal request and duration charges. It removes cold starts but is not free-tier eligible.
- **Worst-case abuse:** the stage throttle is 5 requests per second. Sustained for a whole month that is about 13 million
  requests, or **about $45 of API Gateway charges** (plus backend cost). Mitigations: Cognito rejects unauthenticated
  calls, the optional WAF rate limit is per IP, and the budget alerts email you.

## 5. Security risks and how they are handled

### Lambda optimizations

| Risk | Where | How it is handled here | Residual |
|---|---|---|---|
| Per-request data leaking between requests through module-level state | Initialize outside the handler | Only the client and config live at module level; the event and everything derived from it stay inside the handler | Future code must keep request data and caller identity out of module scope |
| Secrets or credentials cached too long | Initialize outside the handler | The function uses its role credentials, which the SDK refreshes; no secrets are fetched at init | If secrets are added later, rotation is delayed until the environment is recycled |
| Version drift of the runtime SDK | Using the runtime-included SDK | No npm dependencies means no package supply-chain exposure; AWS patches the SDK | Behaviour can change with a runtime update; bundling would pin it but adds npm dependencies |
| Hand-written type conversion | Slim imports (rejected) | Not shipped | It would need its own tests, because conversion bugs can corrupt or mis-type data |
| Retry storms or hangs | Client timeouts (rejected) | SDK defaults apply | Too-aggressive timeouts can amplify load through retries |
| Slightly higher cost per abused cold request | 512 MB | Throttle (5 rps, burst 10), Cognito auth, optional WAF, budget alerts | See the worst-case figure in section 4 |

### Direct DynamoDB read

| Risk | How it is handled | Residual |
|---|---|---|
| **Template injection** (a crafted ID breaking the JSON or query) | The ID is a string *value* in `ExpressionAttributeValues`, never part of the expression, and is escaped; unmatched content types are rejected. Tested with apostrophe, quote, backslash and JSON-breaking IDs: all clean 404s. | VTL has no unit tests; any template edit must keep this pattern and be re-tested on a live table |
| **Over-broad role** | `save-order-api-read-role` can only `Query` one table, carries the permissions boundary, and the module rejects write actions and wildcards | The role can read every order in the table, by design |
| **No ownership (IDOR)** | Documented gap | **Any signed-in user can read any order** by its ID. Fixing it means storing an owner on each order and filtering reads |
| **Order-ID enumeration** | The authorizer blocks anonymous callers | A signed-in user can learn whether an ID exists (200 against 404) |
| **No custom ID validation** | The write path validates IDs with an allow-list; the read path only escapes | Any string up to DynamoDB's key limit reaches DynamoDB and is billed as a read |
| **Less visibility** | Metrics for the API still reach the dashboard | **No Lambda logs, no X-Ray trace, and no API access logs** for reads, so detection and forensics are weaker. Enabling API access logs needs an account-wide role and adds cost |
| **Generic errors** | DynamoDB error details are replaced by fixed 400 and 500 bodies | Good for information leakage, but harder to debug |
| **Wider IAM for the pipeline** | Permission set and deploy role can now pass `save-order-*` roles to API Gateway as well as Lambda | Still limited to that name prefix and capped by the boundary |

## 6. Trade-offs and limitations of the direct read

- **Silent truncation.** One `Query` returns at most 100 items. The response's `itemCount` is the number returned, and
  DynamoDB's continuation marker is dropped, so a client cannot tell whether the list was cut off. A small change to the
  response template could expose a `truncated` flag.
- **Harder to change.** New attributes are not returned until the template is edited, and the template is tied to DynamoDB's
  typed JSON.
- **Harder to test.** Logic in VTL cannot be unit-tested; it was verified against a real table, and `scripts/e2e-test.sh`
  covers it against the deployed stack.
- **5 second timeout** on the integration.

## 7. Choosing: a short process

1. **Measure first:** init time, first-request time, warm duration, memory used (the `REPORT` lines in the logs).
2. **Apply the free, standard things:** init outside the handler, a small package, the right architecture (arm64 here).
3. **Test memory next.** It is the cheapest large lever, and warm requests often get cheaper too.
4. **Try code-level tuning only after that,** and keep a change only if it clearly beats the noise.
5. **Choose structural changes** (direct integration, provisioned concurrency) by requirement and cost, not by habit.
6. **Re-check the security and cost columns** before keeping any change, and re-measure after.

## 8. Not evaluated

esbuild bundling, provisioned concurrency, an HTTP API instead of a REST API (a different feature set and price), an
eventually consistent read, and a Lambda-based read of the same data for a like-for-like latency comparison.
