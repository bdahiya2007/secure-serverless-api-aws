# Demo results: WAF, API cache, DAX and multi-region switched on, then off

On 2026-10-10 the three optional features (all off by default) were switched on one phase at a time on the deployed stack
(`us-east-1`), measured, and switched off again. This page records what was measured, what it cost and what it means.
Background and the decision table are in the [optimization guide](OPTIMIZATION_GUIDE.md); the switches are described in the
[runbook](../terraform/README.md).

**Method.** Every phase used `./scripts/compare-reads.sh` (100 interleaved rounds: direct DynamoDB read, Lambda read and an
unauthenticated "gateway floor" request that API Gateway rejects with 401). One client (WSL) on one network path, a new
connection per request, so absolute numbers include TCP and TLS setup (about 270 ms of every figure). Compare paths and phases
with each other, not with a browser or a client inside the region. Behaviour checks used throw-away users and orders that the
scripts delete on exit. Applies were run by hand with `terraform apply`, one phase at a time.

## Summary

| Question | Answer |
|---|---|
| Does DAX make reads faster? | **No, not measurably.** Lambda read median 322 ms before and 322 ms with DAX. The function itself takes about 6 ms. |
| Does the API cache make reads faster? | **A little:** medians fall by about 21 to 23 ms (6 to 7%) on repeated reads of one order. Most of the ~300 ms is network and TLS, which no cache removes. |
| Do cache and DAX together help more? | **No.** About 8 to 9 ms below the baseline, inside run-to-run noise, and no better than the cache alone. |
| What do they cost in behaviour? | Stale reads for up to the longest TTL (300 s), cached 404s, a flush that takes about 50 s, and a DAX cold start about four times longer. |
| Does the WAF rate limit work? | **Yes**, with a lag: it blocked after about 231 requests, not 100, and held the block for about 5 minutes. |
| What did it cost? | Roughly $0.10 to $0.15 in total (see Cost). |

**Recommendation for this project:** leave all three off. Turn the WAF on when the API is exposed to real traffic. Consider the
API cache only for a hot, read-mostly route where stale data is acceptable. Do not use DAX here.

## Results by phase

### Phase 0: everything off (baseline)

| Path | Median | p90 | Min | Max | Over floor |
|---|---|---|---|---|---|
| API Gateway only (401) | 273 ms | 284 ms | 256 ms | 472 ms | |
| Direct DynamoDB read | 352 ms | 370 ms | 281 ms | 453 ms | +78 ms |
| Lambda read | 322 ms | 337 ms | 291 ms | 516 ms | +49 ms |

Lambda minus direct: -29 ms. The Lambda function itself (104 warm invocations): median 6.0 ms, p90 13.9 ms, max 23.7 ms, billed
7 ms, 113 MB used. Cold: init 333 ms plus a 247 ms first request, billed 581 ms.

### Phase 1: DAX on (1 node `dax.t3.small`, TLS, query and record TTL 60 s)

The cluster took about 10 minutes to create. Checks passed: cluster available, encryption at rest on, TLS port 9111, the Lambda
in the VPC, the cluster endpoint set in its environment, the logs interface endpoint available, no drift.

| Path | Median | p90 | Max | Over floor |
|---|---|---|---|---|
| API Gateway only (401) | 273 ms | 286 ms | | |
| Direct DynamoDB read | 348 ms | 368 ms | 1,289 ms | +76 ms |
| Lambda read through DAX | 322 ms | 353 ms | 899 ms | +50 ms |

Lambda minus direct: -26 ms. **The Lambda median is 322 ms with and without DAX: no gain.** Inside the function (118 warm
invocations) the median was 5.3 ms against 6.0 ms, p90 22.6 ms against 13.9 ms, max 77 ms, billed 6 ms, 119 MB. Repeated reads of
one cached order took 362 to 423 ms, no faster.

| | Without DAX | With DAX |
|---|---|---|
| Cold start (init + first request, billed) | 333 + 247 = 581 ms | 444 + 1,797 = **2,241 ms** |
| First client request after the Lambda joined the VPC and DAX | n/a | 2,856 ms |

Behaviour:
- A read right after a POST of a **new** order was correct (the first read had nothing cached).
- **Stale list:** an order with one item was cached; a second item was POSTed; the DAX read still returned one item while a direct
  read returned two. After 62 s the DAX read returned two.
- **Negative caching:** a read of a missing order returned 404 and the 404 was cached; after the order was created, DAX still
  returned 404 while a direct read returned 200; after the TTL it returned 200.
- DAX serves only eventually consistent reads, so the read Lambda stops using the strongly consistent read while DAX is on.

Verdict: saves under 1 ms of about 320 ms, makes cold starts about 3 s slower, returns stale and empty results for up to the TTL,
and costs about $0.04 to $0.05 per hour. Not worth it for this API. DAX was then switched off (cluster deleted).

### Phase 2: API stage cache on (0.5 GB, TTL 300 s; DAX off)

| Path | Median | p90 | Min | Max | Over floor |
|---|---|---|---|---|---|
| API Gateway only (401) | 272 ms | 280 ms | | 476 ms | |
| Direct DynamoDB read | 331 ms | 372 ms | 273 ms | 598 ms | +59 ms |
| Lambda read | 299 ms | 325 ms | 270 ms | 569 ms | +27 ms |

Lambda minus direct: -32 ms. Against the baseline the medians are 21 ms (direct) and 23 ms (Lambda) lower, about 6 to 7%.
CloudWatch for the run: 167 cache hits and 4 misses; API Gateway's own latency averaged 28.7 ms (integration 24.0 ms), so the
backend is a small part of the roughly 300 ms the client sees.

Behaviour (both routes):
- **Stale reads:** after a write, the old answer kept being served until the TTL ended or the cache was flushed.
- **Negative caching:** a 404 was cached; the order, once created, still returned 404.
- **Flush delay:** `flush-stage-cache` takes about 50 s to take effect. An early test that waited 6 s wrongly suggested the flush
  had failed; checking against the table with consistent queries showed the writes were fine and the flush simply had not finished.
- **Authentication:** requests without a token, or with a bad one, still returned 401 (the authorizer runs before the cache).
- **No mix-ups:** two different order ids returned their own data, and order A still returned A after D was read.
- **Shared between users:** a second user received the response cached for the first. This is acceptable only while any signed-in
  user may read any order.
- **`Cache-Control: max-age=0`** from the client is ignored, so a client cannot force backend load (or fresh data).
- `POST /orders` is never cached.

### Phase 3: WAF rate limit on (100 requests per IP per 5 minutes; cache also on)

Verified: one web ACL attached to the stage, cache available, no DAX cluster, no drift.

Burst test: 300 unauthenticated GETs from one IP in about 100 s (about 3 requests per second):

| Requests | Status | Meaning |
|---|---|---|
| 1 to 231 | 401 | reached API Gateway (no token) |
| 232 to 300 | 403 | blocked by WAF, empty body |

- **Enforcement lags.** WAF evaluates rate rules over a delayed window, so a burst overshot the limit of 100 by more than double
  before blocking began. Treat the limit as approximate, not exact.
- **Block duration:** the IP stayed blocked until about 5 minutes after the last offending request (the first non-403 came
  about 5 minutes after the last burst request), then returned to normal.
- **Per IP, not per user:** while blocked, every request from that IP was blocked, including valid ones. Users behind one shared IP
  (an office or a mobile carrier gateway) share one budget.
- **Blocked requests never reach** API Gateway authorization, the cache or the Lambda, so they cost nothing there.
- CloudWatch for the web ACL over the period showed 177 allowed and 83 blocked requests; the client counted more. The metrics lag
  or sample, so use them for trends, not exact counts.

### Phase 4: everything on (WAF limit raised to 2000 so measurements were not blocked, cache TTL 300 s, DAX 1 node)

Verified: all three switches true, DAX available, stage cache available, no drift.

| Path | Median | p90 | Min | Max | Over floor |
|---|---|---|---|---|---|
| API Gateway only (401) | 282 ms | 310 ms | 270 ms | 856 ms | |
| Direct DynamoDB read | 344 ms | 384 ms | 285 ms | 933 ms | +62 ms |
| Lambda read | 313 ms | 346 ms | 276 ms | 522 ms | +31 ms |

Lambda minus direct: -31 ms. Against the baseline the medians are 8 to 9 ms lower, but the floor itself moved from 273 to 282 ms
between runs, so this is **within noise** and no better than Phase 2.

Behaviour with the API cache in front of DAX:
- The cache-behaviour checks gave the same results as Phase 2 (401 without a token, no id mix-ups, shared between users,
  `max-age=0` ignored, 404 cached, stale after a write on both routes).
- **Staleness is the longest TTL in the chain.** In the DAX test even the "direct" read was stale, because the API cache sat in front
  of it, so it no longer served as ground truth. After DAX's 60 s TTL had passed, the order was still stale because the 300 s API
  cache held the old answer.
- Reads a few seconds after a flush were still stale (the flush delay above).
- DAX reads took 325 to 904 ms with spikes; repeated reads were not faster. The first request after the change took 419 ms this
  time (the earlier 2.9 s was a VPC cold start).

## Second demo: multi-region active/active (global table), 2026-10-10

`enable_multi_region` on (replica in `us-west-2`, a second API stack there, a custom domain and certificate per region, Route 53 latency records
with two health checks), measured with `scripts/demo/multi-region-checks.sh`, then switched off. The design is in the
[runbook](../terraform/README.md#multi-region-active-active-global-table-optional-billed-off-by-default) and the recovery objectives in
[DISASTER_RECOVERY.md](DISASTER_RECOVERY.md). The domain used is the owner's own and is not recorded here.

| Check | Result |
|---|---|
| Apply | Replica `ACTIVE`, 2 HTTPS health checks (healthy within about a minute), 2 latency records. Existing records in the zone (apex, `www`, validation records) unchanged. No drift |
| Health route (no token) | Each region returns `{"status":"ok","region":"..."}` |
| Cross-region sign-in | **Works.** A valid token from the one us-east-1 pool on the us-west-2 API got 404 (accepted, order not found); no token got 401 |
| Replication lag, 10 writes each way (client-side, including the polling read) | us-east-1 to us-west-2: 473 to 1,186 ms, median about 860 ms. us-west-2 to us-east-1: 328 to 1,227 ms, median about 800 ms. CloudWatch `ReplicationLatency`: average 569 ms, maximum 903 ms |
| Conflict: the same item written in both regions at once (quantity 10 and 20) | After 8 s both regions showed 20. **Last writer wins; the other write was lost silently** |
| Custom domain | Answered over HTTPS with a free certificate per region; from this client it resolved to us-west-2 (the nearest); an authenticated read through it worked |
| Failover, forced (the answering region's health check inverted) | The domain answered from the other region after **about 31 s** (polled every 10 s) |
| Data cleanup | 0 order rows in both regions, 0 test users |

How to read the numbers:
- **The 31 s is not a recovery time.** Inverting a health check flips its status at once, so it excludes detection. A real failure needs three failed 30 s checks (about
  90 s) plus up to 60 s of DNS caching: roughly **1.5 to 3 minutes**. The failback reading ("back after 0 s") was unreliable and is not reported.
- The replication figures include the cost of the polling read itself (a Lambda call), so true replication is a little quicker than the client-side numbers.
- One client, one run, one failure type. Not a load test.

**What went wrong on the way.** The first apply stopped while creating the replica with `UnrecognizedClientException: The security token included in the request is invalid`
(in us-west-2), after the custom domain had taken about a minute. Nothing billable existed yet. After a fresh `ssologin` the same apply completed; the likely cause is the SSO
session expiring during a long apply (not confirmed). **Run `ssologin` before a long apply.** Separately, my first failover step inverted the primary's health check although the
other region was the one answering, so it would have shown no change; the script now fails whichever region is answering.

**Cost.** The setup was on for about 20 minutes (replica, second stack and two health checks). A few cents, estimated from list prices; the bill had not been read, and the
Route 53 health check price (roughly $1 to $2 each per month, prorated) was not verified. Idle, the health checks alone would be a few dollars a month, which is why it is off by default.

**Shutdown verified** after a plain `terraform apply`: `multi_region_enabled` false; no replica and no `Orders` table in us-west-2; no health checks; no certificates, custom domains,
APIs or Lambdas in us-west-2; no `-dr` IAM roles; the zone back to its original records; the existing website returning 200; `terraform plan` showing no changes.

## Third demo: sign-in with Google, in one and in two regions (2026-10-10 and 11)

`enable_federated_signin` on (Cognito hosted pages with Google, a guard Lambda on the pre sign-up and pre token generation triggers), first alone, then with
`enable_multi_region` so each region has its own pool and guard. The procedure to repeat it is in [COGNITO_TESTING_RUNBOOK.md](COGNITO_TESTING_RUNBOOK.md); the
design is in the [runbook](../terraform/README.md#sign-in-with-google-optional-off-by-default). The Google client, domain, prefix and addresses used are the owner's and are not recorded here.

| Test | Result |
|---|---|
| Resources created (one region) | Lite plan; both triggers attached; Google provider with `openid email profile` and attribute mapping; a separate code-flow-only, Google-only, secretless app client; guard 5 s, 128 MB |
| Sign-in with an allowed address | Token from the primary pool (federated, about an hour, `email_verified`); guard `allow` on sign-up, sign-in and refresh |
| A Google test user **not on the list** | Refused at sign-up (guard `deny`, Lambda error 1); **no user was created** |
| **Lockout:** remove an address, then refresh | **Refused:** `PreTokenGeneration failed ... Sign-in is not permitted for this account` (guard `deny` on the refresh trigger) |
| An ID token issued before the removal | **Still accepted by the API** (404, accepted) until it expires: a stateless-token limit of up to 60 minutes |
| Guard logs | Decision and trigger only; no email (0 `@` characters in either region's logs) |
| Two regions: each pool's token on each API | **4 of 4 accepted** (the Virginia pool's token on the Oregon API and the Oregon pool's token on the Virginia API); no token or a garbage token 401 on both |
| Two regions: write and read across regions | Write through one region 201, read back 200, readable in the other region on the first poll |
| Two regions: refresh | Allowed address refreshed through the second region's guard |
| Switch off | Pool domain, provider, app client, both guards, the second pool and the whole second-region stack removed; the replica, health checks and certificates gone; the zone back to its original records; `terraform plan` clean. The two Google test users remain in the (deletion-protected) primary pool until deleted |

**Mistakes and delays, all avoidable** (each is now handled or documented): the first two-region apply used the literal **placeholder address** (both guards admitted nobody real; fixed by a second apply);
the helper script opened the **normal browser**, which reused the other Google session, so the guard rightly refused it (the script now has `--private` and no longer auto-opens a normal window);
the callback link was **re-pasted** after use ("refused to connect" is expected once the script has exited); an apply was **paused with Ctrl+Z**, holding the state lock; one apply was run from the wrong folder;
and a null Terraform output made `federated-checks.sh` stop early with multi-region off (fixed). WSL2 networking was tested and is not a cause.

**Cost.** Google sign-in alone: nothing (Cognito Lite and Lambda free tiers; Google is free). The two-region part had the multi-region stack on for about 30 minutes: a few cents, estimated at
about $0.07 per hour from list prices; the bill was not read.

## Shutdown (End) verified

After the final `terraform apply` with no variables (about 20:10 UTC), a check found: `waf_enabled`, `api_cache_enabled` and `dax_enabled`
all `false`; no DAX clusters (the cluster took about 2 minutes to disappear after the apply returned); no web ACLs; no VPC endpoints;
the stage cache off (it showed `DELETE_IN_PROGRESS`, then `NOT_AVAILABLE`, about a minute after the apply); the read Lambda out of the
VPC with no `DAX_ENDPOINT`; no leftover orders or users; and `terraform plan` reporting no changes.

## Cost

Estimated from run times and list prices; the bill itself lags and was not queried. DAX run times come from the cluster's
created and deleted events.

| Item | Time on | Estimate |
|---|---|---|
| DAX, 1 x `dax.t3.small` (about $0.04 per hour) | Phase 1: about 30 to 45 min. Phase 4: about 1 h | about $0.05 to $0.07 |
| Logs interface endpoint, needed while DAX is on | the same windows | about $0.01 to $0.02 |
| API stage cache, 0.5 GB (about $0.02 per hour, rate not verified) | about 1.5 h | about $0.03 |
| WAF web ACL and rule (about $0.008 per hour) | about 1 h, a few hundred requests | about $0.01 |
| API Gateway, Lambda, DynamoDB, Cognito | a few thousand requests | at most $0.02, probably free tier |

**Total: roughly $0.10 to $0.15.** While all three are on the rate is about **$0.07 per hour** (about $50 a month if left running),
which is why they default to off, why `deploy.yml` stops while DAX is on, and why the deploy applies with the others off.

## How to reproduce

Run from the repository root with an AWS session (`aws sso login`). Applies are run by hand; every `terraform apply` ends with the
confirmation prompt (`yes`). **Each apply replaces the whole switch set, so repeat every switch you want to keep.** Billing starts at
each apply; do the End step when finished. The scripts create throw-away users and orders and delete them on exit.

| Phase | Apply (in `terraform/environments/dev`) | Then run (from the repository root) |
|---|---|---|
| 0: baseline | `terraform apply` | `ROUNDS=100 ./scripts/compare-reads.sh` |
| 1: DAX | first `./scripts/build-dax-package.sh`, then `terraform apply -var enable_dax=true` (about 10 minutes) | `scripts/demo/dax-checks.sh`, `ROUNDS=100 ./scripts/compare-reads.sh` |
| 2: API cache | `terraform apply -var enable_api_cache=true` (about 4 minutes) | `scripts/demo/cache-checks.sh`, `ROUNDS=100 ./scripts/compare-reads.sh` |
| 3: WAF | `terraform apply -var enable_api_cache=true -var enable_waf=true` | `scripts/demo/waf-checks.sh 300`, then wait about 5 minutes for the block to clear |
| 4: all on | `./scripts/build-dax-package.sh`, then `terraform apply -var enable_api_cache=true -var enable_waf=true -var enable_dax=true -var waf_rate_limit=2000` | `scripts/demo/cache-checks.sh`, `scripts/demo/dax-checks.sh`, `ROUNDS=100 ./scripts/compare-reads.sh` |
| Multi-region (second demo) | `ssologin`, then `terraform apply -var enable_multi_region=true -var multi_region_domain=api.example.com -var route53_zone_name=example.com` (an existing hosted zone is needed) | `API_DOMAIN=api.example.com scripts/demo/multi-region-checks.sh`, then with `SIMULATE_FAILOVER=1`; remove with `terraform apply` |
| End | `terraform apply` (no variables) | `terraform output` must show `waf_enabled`, `api_cache_enabled` and `dax_enabled` as `false` |

Notes: phase 1 was run with the API cache off, which is why its DAX result is clean; in phase 4 the "direct read" in
`dax-checks.sh` is served by the API cache and is not a ground truth. After the End step, check there are no DAX clusters
(`aws dax describe-clusters`), no web ACLs (`aws wafv2 list-web-acls --scope REGIONAL`) and that the stage cache is off
(`aws apigateway get-stage`, `cacheClusterEnabled`). Set the WAF limit back to its default by leaving `waf_rate_limit` out.

## What changed in the documentation because of these results

- [README](../README.md) and the [optimization guide](OPTIMIZATION_GUIDE.md): the cache and DAX are now measured, not expected.
- [Runbook](../terraform/README.md): the flush delay, negative caching, DAX cold start and WAF enforcement lag.
- [Testing guide](TESTING.md): the flush wait.

## Limits of these results

One client and network path, one day, 100 rounds per phase, a single order read repeatedly (the best case for a cache; unique ids
always miss), and small items. The floor moved by about 10 ms between runs, so differences under about 10 ms are noise. A client in
`us-east-1`, a hot set of many ids, larger items or more traffic could change the picture. The cache price per hour is from list
pricing and was not confirmed against a bill.
