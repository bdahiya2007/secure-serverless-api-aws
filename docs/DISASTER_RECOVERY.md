# Disaster recovery and multi-region availability

What this project can and cannot survive, what to expect when a region fails, and how to test it. The design is optional and **off by
default** (`enable_multi_region`, billed); the measured results are in [DEMO_RESULTS.md](DEMO_RESULTS.md) and the build details in the
[runbook](../terraform/README.md#multi-region-active-active-global-table-optional-billed-off-by-default).

## What is built

```
client -> Route 53 (latency routing, health-checked) -+-> API Gateway -> Lambda -> Orders   (us-east-1)
                                                      +-> API Gateway -> Lambda -> Orders   (us-west-2)
                          the two Orders tables replicate to each other (DynamoDB global table)
                          one Cognito user pool, in us-east-1, validated by both APIs
```

Active/active: both regions accept reads and writes at the same time, and Route 53 answers with the region closest to the client
that passes its health check. With the switch off (the default) there is **no** disaster recovery: one region, and a regional
failure means an outage. Point-in-time recovery is also off (billed), so there is no backup either.

## Objectives (what to expect)

| Measure | Value | Basis |
|---|---|---|
| **RPO** (data you can lose) | Normally under 2 seconds of writes; unbounded for a write made in the failed region that had not replicated yet | Measured replication lag was 0.3 to 1.2 s (median about 0.8 s; CloudWatch average 569 ms, maximum 903 ms). Replication is asynchronous |
| **RTO** (time to serve again) for API and data | About 1.5 to 3 minutes for a real failure | Three failed 30 s health checks (about 90 s) plus up to 60 s of DNS caching. **Measured 31 s** only for a *forced* failure, which skips the detection time. Clients that cache DNS longer take longer |
| **RTO for new sign-ins** if us-east-1 Cognito is down | Not covered by default (one user pool, in us-east-1). With Google sign-in and multi-region on, sign-in goes through the other region's pool; verified working, not tested during a real Cognito outage | See gap 1 below |
| Concurrent writes to one item in both regions | One write is lost | Last writer wins (measured: both regions converged to the later write) |

These are from one short demo from one client and one failure type. Treat them as order-of-magnitude figures, not guarantees.

## Failure scenarios

| What fails | What happens | Covered? |
|---|---|---|
| us-east-1 API Gateway or Lambda | The health check fails; Route 53 stops answering with us-east-1; clients reach us-west-2 after detection plus DNS caching. Existing tokens keep working | **Yes** |
| us-west-2 API Gateway or Lambda | The same, in the other direction | **Yes** |
| DynamoDB impaired in one region | Writes and reads in that region fail, but the **health check does not notice** (it only checks that API Gateway is up) and Route 53 keeps sending clients there | **No.** Needs a deeper health check (a read through the Lambda), or a manual failover |
| us-east-1 Cognito down | With Google sign-in and a pool in each region (built and verified: both pools' tokens work on both APIs; not tested during a real Cognito outage): sign in through the other region's pool. Without it: valid tokens keep working in us-west-2 until they expire (about an hour), with no new sign-ins or refreshes | **Partly** (see gap 1) |
| Both regions down, or a bad deploy to both | Outage; replication copies bad writes and deletes to the other region | **No.** A global table is not a backup. Use point-in-time recovery for that |
| Accidental delete or corruption of data | Replicated to both regions within seconds | **No** (same reason) |
| Route 53 or the DNS name itself | Clients cannot resolve the name | **No.** Route 53's data plane is highly available but it is still one dependency |
| The Terraform state or deploy pipeline | The pipeline cannot manage the second region (by design); local apply is needed | Operational gap |

## Manual failover and failback

Automatic: nothing to do. To move traffic by hand (planned maintenance, or a failure the health check cannot see):

```bash
cd terraform/environments/dev
IDS=$(terraform output -json multi_region_health_check_ids)           # health check per region
aws route53 update-health-check --health-check-id <id of the region to drain> --inverted      # force it unhealthy
# DNS moves within about a minute; confirm with: curl -s https://<your api name>/health   (shows the answering region)
aws route53 update-health-check --health-check-id <same id> --no-inverted                     # fail back
```

Inverting a check changes only the health check, never data or the API. Failing back is immediate for the check and then limited by DNS
caching. Do not drain both regions.

## Testing it

Run `scripts/demo/multi-region-checks.sh` as described in [TESTING.md](TESTING.md#7-multi-region-activeactive-optional-billed): health,
cross-region sign-in, replication both ways, a conflict, the domain, and (with `SIMULATE_FAILOVER=1`) a forced failover. The
script restores the health checks on exit. A real disaster test (breaking a Lambda's permissions in one region and confirming the other serves)
is the next level and has not been done here. Repeat the test after any change to routing, the APIs or the table, and at least every few months.

## Known gaps and what to do before relying on this

1. **Sign-in in one region.** Built behind `enable_federated_signin` (with multi-region on): a pool in each region, both APIs trusting both pools, and
   Google as the identity provider so there are no users to copy. **Verified live**: each pool's token was accepted by both APIs, and a sign-in and refresh worked in each region
   ([runbook](COGNITO_TESTING_RUNBOOK.md)). Not verified: sign-in while one region's Cognito is actually down. Whenever the switch is off, sign-in depends on the us-east-1 pool. Owner ids must come from Google (email or Google subject), not Cognito's `sub`, which differs per pool. See the
   [runbook](../terraform/README.md#sign-in-with-google-optional-off-by-default).
2. **Shallow health check.** It proves API Gateway is up, not DynamoDB or Lambda. Add a deeper check before trusting automatic failover for data-plane failures.
3. **No backup.** Turn on point-in-time recovery (billed per GB) so a bad write or delete can be undone; replication alone repeats it.
4. **Conflicts.** Last-writer-wins is fine for this data (orders keyed by order and item). It is not fine for counters or balances.
5. **The pipeline cannot deploy the second region.** The deploy role has no Route 53, ACM or second-region access, so the stack is applied locally and the
   deploy workflow refuses to run while it is on. Decide whether to grant the role those scoped permissions before relying on this day to day.
6. **WAF, alarms and dashboards** are not wired for the second region (the WAF follows `enable_waf` when set; there are no second-region alarms or dashboard).
7. **Data residency.** Orders live in two regions while it is on.
8. **Cost.** Replicated writes, replica storage, a second stack and two health checks: cents for a demo, a few dollars a month idle (health checks), more with traffic.
