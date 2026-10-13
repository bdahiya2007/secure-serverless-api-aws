# Runbook: Cognito sign-in testing in one and two regions

A repeatable, step-by-step procedure to test sign-in end to end: the password flow, sign-in with Google through the hosted pages,
the allow-list guard, and the same in two regions (a user pool and a guard in each, both APIs trusting both pools). Use it for a demo,
after a change to sign-in, or to build confidence in a new environment.

**Everything here uses placeholders.** Your domain, Cognito prefix, Google client ID and secret, addresses, account ID and pool IDs
are yours: keep them in your shell and never commit them. See [Safety rules](#0-safety-rules-read-first).

Contents: [0 Safety](#0-safety-rules-read-first) | [1 What is tested](#1-what-is-tested) | [2 Prerequisites](#2-prerequisites-once) |
[3 Google setup](#3-google-oauth-client-once-free) | [4 Variables](#4-variables-and-where-they-live) | [5 Baseline: password flow](#5-baseline-password-flow-no-google) |
[6 Part A, one region](#6-part-a-google-sign-in-one-region) | [7 Part B, two regions](#7-part-b-google-sign-in-in-two-regions) |
[8 Switch off and clean up](#8-switch-off-verify-and-clean-up) | [9 Repeat in a new environment](#9-repeating-this-in-another-environment) |
[10 Troubleshooting](#10-troubleshooting-every-problem-met-so-far) | [11 Results of the first run](#11-results-of-the-first-run-2026-10-10-and-11)

## 0. Safety rules (read first)

| Rule | Why |
|---|---|
| The Google **client secret** goes only in your shell (`read -rs TF_VAR_google_client_secret`). Never paste it into chat, a file or a command line. | It proves Cognito is your app to Google. It is stored in the Terraform state (private, encrypted bucket), nowhere else. |
| The **allowed addresses** go only in `TF_VAR_allowed_emails` in your shell. | Personal data. They end up in the guard's environment variable and the state. |
| **Never paste or reload a callback link** (`http://localhost:8765/callback?code=...`). | It is the *result* of a sign-in, works once, and shows "refused to connect" afterwards. A leaked code is short-lived and useless without the script's private PKCE value, but do not share it anyway. |
| **Tokens are credentials.** The helper writes them to `~/.cache/orders-api/` (mode 0600) and never prints them. Delete them when done. | An ID token works for about an hour; a refresh token for about 7 days. |
| Before committing anything from a test, scan the staged content (`python3 scripts/secret-scan.py --staged`; it now flags Google client secrets and IDs, Google tokens and real Cognito hosted domains) and also check for your domain, prefix, app client IDs, zone ID, account ID and addresses, which it cannot know: put them in your private block list ([SECRET_SCANNING.md](SECRET_SCANNING.md)). | The repository is public. |
| Cost: the one-region test costs nothing; the two-region test costs cents per half hour. Get approval, time-box it and switch off. | The replica, second stack and health checks bill by the hour. |

## 1. What is tested

| # | Check | Expected |
|---|---|---|
| T1 | Password flow, primary pool (CLI user) | 201 write, 200 read; wrong or no token 401 |
| T2 | Google sign-in with an **allowed** address | Token issued; issuer is that region's pool; federated |
| T3 | Google sign-in with a **Google test user not on the list** | Refused; no Cognito user created |
| T4 | **Lockout:** remove an address, then refresh its token | Refresh refused (the guard runs on every token) |
| T5 | A token issued before removal | Still accepted until it expires (up to 60 minutes): a known limit |
| T6 | Each pool's token on **each** API (two regions) | Accepted by both (200 or 404, never 401) |
| T7 | Write in one region, read in the other | Replicated within a few seconds |
| T8 | Refresh through each region's guard | Allowed address succeeds |
| T9 | Guard logs | Only the decision and the trigger; **no email** |
| T10 | Switch off | All switches false; nothing left in either region; DNS records as before |

## 2. Prerequisites (once)

- Linux or WSL2 shell with `terraform` (1.16+), `aws` CLI v2, `python3`, `curl`, `openssl`, `git`, and Node 22+ for the unit tests.
- AWS access to the account (SSO is assumed: `aws sso login`, here `ssologin`) and your profile exported: `export AWS_PROFILE=<profile>`.
  **Refresh the session before any long apply**: it can expire mid-apply and fail partway (see Troubleshooting).
- A checkout of this repository on `main`, up to date, with the sign-in code merged (`src/signin-guard`, `scripts/demo/google-signin.py`).
- A Google account to create the OAuth client (free, no billing), and one or two Gmail addresses to sign in with.
- For the two-region test: an existing Route 53 public hosted zone and a name inside it for the API (see the [runbook](../terraform/README.md#multi-region-activeactive-global-table-optional-billed-off-by-default)).
- A browser that can open a **private window** (Chrome, Edge, Firefox). On WSL2, `localhost` from Windows reaches a listener inside WSL (tested for `localhost` and `127.0.0.1`; IPv6 `::1` is not reachable, and browsers fall back to IPv4).
- Unit tests pass before you start: `node --test "src/*/*.test.mjs"`.

## 3. Google OAuth client (once, free)

Console labels change often; treat these as a guide.

1. https://console.cloud.google.com, sign in with your Gmail account (no billing needed). Create a project (any name).
2. **APIs & Services, OAuth consent screen** (Google Auth Platform, *Get started*): app name, your support email; **Audience: External**; contact email; agree; *Create*.
3. **Audience:** publishing status must say **Testing** (never "Publish app"). Under **Test users** add every address you will sign in with, including any you want the guard to **refuse** (T3).
4. **Data access:** the defaults `openid`, `.../auth/userinfo.email`, `.../auth/userinfo.profile` are non-sensitive and enough.
5. **Clients, Create client:** type **Web application**, any name, leave JavaScript origins empty, and add one **Authorized redirect URI per region you will test**:
   `https://<prefix>.auth.<primary-region>.amazoncognito.com/oauth2/idpresponse` and, for two regions, `https://<prefix>.auth.<second-region>.amazoncognito.com/oauth2/idpresponse`.
6. Copy the **Client ID** (not secret) and the **Client secret** (shown at creation; keep it in a password manager). Changes can take minutes to apply.

`<prefix>` is the hosted-domain prefix you choose: lowercase letters, numbers and hyphens, 2 to 63 characters, not containing `aws`, `amazon` or `cognito`, and **unique per region across all AWS accounts**. Pick one that does not identify you or your account.

## 4. Variables and where they live

| Name | Example | Secret? | Where it goes |
|---|---|---|---|
| `enable_federated_signin` | `true` | no | `-var` on `terraform apply` |
| `federated_domain_prefix` | `<prefix>` | no (live resource name) | `-var`; not committed |
| `google_client_id` | `<client id>.apps.googleusercontent.com` | no (but not committed) | `-var`; not committed |
| `google_client_secret` | | **yes** | `TF_VAR_google_client_secret`, set with `read -rs` |
| `allowed_emails` | `["you@example.com"]` | personal data | `TF_VAR_allowed_emails` (JSON list), shell only |
| `enable_multi_region`, `multi_region_domain`, `route53_zone_name` | `true`, `api.example.com`, `example.com` | no (not committed) | `-var`, for Part B only |

**Every `terraform apply` replaces the whole switch set.** Repeat every switch you want to keep, or Terraform removes it. Always apply from
`terraform/environments/dev` (running it elsewhere gives "No configuration files").

Set the secret without leaving it in your shell history:

```bash
read -rs TF_VAR_google_client_secret && export TF_VAR_google_client_secret    # paste at the silent prompt
export TF_VAR_allowed_emails='["you@example.com"]'                            # your REAL allowed address(es), JSON, double quotes inside single
```

**Check the address you typed before pressing Enter on the apply.** A placeholder or typo (the first run applied the literal placeholder text) produces a guard that admits nobody real; the fix is a second apply.

## 5. Baseline: password flow (no Google)

Confirms the API and the primary pool before anything federated. No variables needed.

```bash
cd <repo>
./scripts/e2e-test.sh                         # 16 cases: validation, auth, reads, injection checks; cleans up after itself
```

Optional, to test a CLI user by hand (and, with two regions, in the second pool): see the [runbook's Cognito section](../terraform/README.md#cognito-user-pool).
In the second region use `terraform output dr_user_pool_id` and `terraform output dr_user_pool_client_id`, and `--region <second-region>` on every `aws cognito-idp` call.

## 6. Part A: Google sign-in, one region

Cost: nothing (Cognito Lite plan and Lambda free tiers; Google is free). Time: about 20 minutes.

**A1. Apply**

```bash
cd <repo>/terraform/environments/dev
# secret and allowed_emails already exported (section 4)
terraform apply -var enable_federated_signin=true -var federated_domain_prefix=<prefix> -var google_client_id=<client id>
```

Expect about 9 resources to add and 1 change (the pool). Type `yes` only if nothing unexpected is listed. If it says the prefix is taken, choose another and update the Google redirect URIs.

**A2. Verify what was created** (read-only; none of this prints a secret or an address)

```bash
POOL=$(terraform output -raw user_pool_id)
aws cognito-idp describe-user-pool --user-pool-id "$POOL" \
  --query 'UserPool.{tier:UserPoolTier,preSignUp:LambdaConfig.PreSignUp!=null,preTokenGen:LambdaConfig.PreTokenGenerationConfig.LambdaVersion,domain:Domain!=null}'
aws cognito-idp describe-identity-provider --user-pool-id "$POOL" --provider-name Google \
  --query '{type:IdentityProvider.ProviderType,scopes:IdentityProvider.ProviderDetails.authorize_scopes,map:IdentityProvider.AttributeMapping}'
aws cognito-idp describe-user-pool-client --user-pool-id "$POOL" \
  --client-id "$(terraform output -json federated_signin | python3 -c 'import sys,json; print(json.load(sys.stdin)["<primary-region>"]["client_id"])')" \
  --query 'UserPoolClient.{flows:AllowedOAuthFlows,scopes:AllowedOAuthScopes,idps:SupportedIdentityProviders,callbacks:CallbackURLs,secret:ClientSecret!=null,auth:ExplicitAuthFlows}'
aws lambda get-function-configuration --function-name save-order-signin-guard --query '{timeout:Timeout,mem:MemorySize,runtime:Runtime}'
```

Expect: tier `LITE`; both triggers attached (`V1_0` for pre token generation); provider type `Google` with scopes `openid email profile`; client flows `["code"]`, identity providers `["Google"]`, callback `http://localhost:8765/callback`, **no client secret**, only `ALLOW_REFRESH_TOKEN_AUTH`; guard 5 s and 128 MB.

**A3. Sign in with an allowed address (T2).** From the repository root, with the AWS profile exported:

```bash
scripts/demo/google-signin.py --private
```

A private browser window opens. Enter the **allowed** address yourself (type it; do not accept an auto-selected account). Wait for
the page "Signed in. You can close this tab" and for the terminal to say "Saved tokens for ...". Do not press Ctrl+Z, do not close the
terminal, do not reload the callback page. If the window does not open, copy the printed link into a private window yourself.

*Why private:* a normal window reuses your existing Google session and signs in as that account, which may not be on the list.

Confirm **which account** signed in without printing it (compare hashes):

```bash
python3 - <<'PY'
import base64,json,os,hashlib,time
c=json.loads(base64.urlsafe_b64decode(open(os.path.expanduser("~/.cache/orders-api/id_token-<primary-region>")).read().split(".")[1]+"=="))
print("age (min):",round((time.time()-c["iat"])/60,1),"| pool region:",c["iss"].split("/")[-1].split("_")[0],"| federated:","identities" in c,"| email hash:",hashlib.sha256(c["email"].lower().encode()).hexdigest()[:8])
PY
# compare with the allowed address's hash:  python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].lower().encode()).hexdigest()[:8])" you@example.com
```

**A4. API checks (T1, T2):** `scripts/demo/federated-checks.sh`. Expect no token and a garbage token 401; the Google token accepted
(404 for a missing order; **401 means refused**); a write 201 and a read back 200. It removes its order rows.

**A5. Refusal test (T3).** Run `scripts/demo/google-signin.py --private` again and sign in with a Google test user that is **not** on the list.
Expect Google to let you through and Cognito to refuse: the callback shows an error such as "PreSignUp failed with error Sign-in is not permitted
for this account", and **no new user is created**. Check:

```bash
aws cognito-idp list-users --user-pool-id "$POOL" --query 'length(Users)'      # unchanged
aws logs filter-log-events --log-group-name /aws/lambda/save-order-signin-guard --start-time $(( ($(date +%s) - 600) * 1000 )) \
  --query 'events[].message' --output text | grep -o '"decision":"[a-z]*","triggerSource":"[A-Za-z_]*"'    # a deny line
```

A browser page that says "refused to connect" at this point is normal: the callback went to the script, which had already exited, or the sign-in
was refused. The guard's log is the evidence, not the page.

**A6. Lockout test (T4, T5).** You need a user who already has a profile and a saved refresh token (from A3).

1. Change the allow-list so that address is **no longer** on it (use only some other address) and re-apply the same command from A1. Expect 1 change.
2. Refresh the saved token: `scripts/demo/google-signin.py --refresh`. Expect **"Token request refused: HTTP 400 ... PreTokenGeneration failed with error Sign-in is not permitted for this account"**.
3. The guard log shows `deny TokenGeneration_RefreshTokens`.
4. *Known limit (T5):* an ID token issued **before** the removal still works on the API until it expires (up to 60 minutes), because it is a stateless
   token. To cut access faster, also run `aws cognito-idp admin-user-global-sign-out` (and `admin-disable-user`) for that user, or shorten the token lifetime.
5. Restore the allow-list to what you want to keep and re-apply, or go on to Part B.

**A7. Guard logs (T9):** the log lines contain only `decision` and `triggerSource`. Check: `... --query 'events[].message' --output text | grep -c '@'` must print `0`.

## 7. Part B: Google sign-in in two regions

Cost: the stack's idle rate is mostly the two Route 53 health checks (roughly $3 a month in all, about $0.004 an hour; unverified), plus per-request and replicated-write charges: cents for a 30 minute test. (The $0.07 an hour figure elsewhere is for DAX, the cache and the WAF all on, not for this stack.) **Get approval first, apply, test quickly and switch off.**
It also needs the Route 53 pieces (zone and a name), described in the [multi-region runbook](../terraform/README.md#multi-region-activeactive-global-table-optional-billed-off-by-default).

**B1. Apply**

```bash
cd <repo>/terraform/environments/dev
# ssologin first: the apply takes several minutes and an expired session fails it partway
terraform apply -var enable_federated_signin=true -var federated_domain_prefix=<prefix> -var google_client_id=<client id> \
                -var enable_multi_region=true -var multi_region_domain=<api.example.com> -var route53_zone_name=<example.com>
```

Expect a large plan (roughly 80 resources to add: the replica, the second API stack, a pool and guard in the second region, certificates, health
checks and records). **Check it does not change the existing records in your zone** (apex, `www`, your other names). Run it from **one** terminal,
and see "Troubleshooting" if you get a state-lock error.

**B2. Verify (T6 setup).** Everything from A2 for the primary pool, plus:

```bash
terraform output federated_signin_enabled multi_region_enabled        # both true
aws dynamodb describe-table --table-name Orders --query 'Table.Replicas[].[RegionName,ReplicaStatus]'   # <second-region> ACTIVE
DRPOOL=$(terraform output -raw dr_user_pool_id)
aws cognito-idp describe-user-pool --region <second-region> --user-pool-id "$DRPOOL" --query 'UserPool.{tier:UserPoolTier,domain:Domain!=null}'
aws route53 list-health-checks --query 'length(HealthChecks)'          # 2
```

Check the guards hold **your real address and not a placeholder**, without printing it:

```bash
for r in <primary-region> <second-region>; do f=save-order-signin-guard; [ "$r" != <primary-region> ] && f=save-order-signin-guard-dr
  v=$(aws lambda get-function-configuration --region $r --function-name $f --query 'Environment.Variables.ALLOWED_EMAILS' --output text)
  echo "$r entries=$(echo "$v" | tr ',' '\n' | wc -l) hash=$(python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].strip().lower().encode()).hexdigest()[:8])" "$v")"; done
```

Compare the printed hash with the hash of your allowed address (A3). Fix with a re-apply if it is wrong (1 or 2 changes).

**B3. Sign in through each region's pool.** One run **per region**, sequentially (both use port 8765), each in a private window with the **same allowed address**:

```bash
scripts/demo/google-signin.py --private                                 # the primary pool
scripts/demo/google-signin.py --private --region <second-region>        # the second pool (a new user is created there)
```

Wait for "Saved tokens for <region>" before starting the next. Confirm each token (A3's snippet, with the matching region in the file name) is federated, from that region's pool, and for the allowed address.

**B4. Cross-region checks (T6, T7).**

```bash
scripts/demo/federated-checks.sh
```

Expect: no token and a garbage token 401 on **both** APIs; the primary pool's token **and** the second pool's token accepted by **both** APIs (four accepted lines, 404 each);
a write through the primary 201 and read back 200; the same order read in the second region 200 (replication, normally within a second or two).

**B5. Refresh in the second region (T8).** `scripts/demo/google-signin.py --refresh --region <second-region>` must print "Saved tokens". The second region's guard log
(`/aws/lambda/save-order-signin-guard-dr`, in the second region) shows `allow` decisions and no email.

**B6. Failover (optional, T6 extended).** With the password test user from section 5 for each region or with a Google token, run
`API_DOMAIN=<api.example.com> SIMULATE_FAILOVER=1 scripts/demo/multi-region-checks.sh`. It forces the answering region's health check to fail, waits for the name to
answer from the other region (about 30 s for a forced failure; a real failure takes about 1.5 to 3 minutes), restores the checks and cleans up. See [DISASTER_RECOVERY.md](DISASTER_RECOVERY.md).

**B7. Optional guard refusal in the second region.** Repeat A5 with `--region <second-region>`; expect a `deny` in the second region's guard log and no new user in the second pool.

## 7b. Hosted sign-in for the browser client (no Google)

The browser app signs in on Cognito's hosted pages with a username and password, through a separate **browser client** (`cognito_domain_prefix` and `browser_callback_urls`; see the [runbook](../terraform/README.md#hosted-sign-in-for-a-browser-front-end-optional-off-by-default)). Nothing in Parts A and B is needed for it, and it needs no Google account or secret.

```bash
scripts/demo/hosted-signin-check.py             # no browser: authorize, login form, wrong password, code, PKCE token exchange, the API; cleans up
cd tests/e2e && AWS_PROFILE=... npm run test:live   # a real browser through the same hosted pages and the real API; creates and removes a temporary user
```

Expect 12 of 12 checks from the first and a passing live test from the second ([TESTING.md](TESTING.md#12-browser-tests-testse2e)). The same traps apply as in section 10: a callback URL must match **exactly**, and the repository variables must be set before the merge.

## 8. Switch off, verify and clean up

```bash
cd <repo>/terraform/environments/dev
unset TF_VAR_google_client_secret TF_VAR_allowed_emails
ssologin
terraform apply                       # no variables: everything off. Type yes after reading the plan (only destroys)
```

Verify (all of these were true after the first run):

```bash
terraform output federated_signin_enabled multi_region_enabled api_cache_enabled dax_enabled waf_enabled      # all false
aws dynamodb describe-table --table-name Orders --query 'Table.Replicas'                                      # null
aws dynamodb describe-table --table-name Orders --region <second-region>                                      # ResourceNotFound
for r in <primary-region> <second-region>; do aws cognito-idp list-user-pools --max-results 10 --region $r --query length\(UserPools\); \
  aws apigateway get-rest-apis --region $r --query length\(items\); aws apigateway get-domain-names --region $r --query length\(items\); done
aws route53 list-health-checks --query 'length(HealthChecks)'                                                 # 0
aws route53 list-resource-record-sets --hosted-zone-id <zone id> --query 'ResourceRecordSets[].[Name,Type]'   # your original records only
curl -s -o /dev/null -w '%{http_code}\n' https://<your site>                                                  # still 200
terraform plan                                                                                                # No changes
```

Expect one user pool and one API in the primary region (the production ones) and none in the second.

Clean up locally and in the pool:

```bash
scripts/demo/google-signin.py --forget ; scripts/demo/google-signin.py --forget --region <second-region>     # delete saved tokens
# optional: remove the Google test users from the primary pool (they are recreated at the next sign-in)
aws cognito-idp list-users --user-pool-id "$POOL" --query 'Users[].Username'
aws cognito-idp admin-delete-user --user-pool-id "$POOL" --username <username from the list>
```

The primary pool is deletion protected, so its users stay after the switch is off; the second region's pool is deleted with the stack.

## 9. Repeating this in another environment

For a new account, region pair or environment (staging, production), change only what is yours; the procedure is the same:

1. **New Google client** (or add redirect URIs to the existing one): one URI per Cognito region and prefix. A different prefix per environment is cleanest.
2. **Prefix:** unique per region across all AWS accounts. Terraform fails at apply if it is taken.
3. **Allow-list:** the addresses for that environment. Keep it in your shell or your secrets tool, never in a file in the repository.
4. **State and permissions:** each environment has its own state and role; the demo is applied locally because the pipeline's deploy role cannot manage the second region, Route 53 or ACM. If you want the pipeline to run it, grant those scoped permissions first and decide who approves.
5. **Domain:** a name in an existing hosted zone (Part B only), and a certificate per region (created by Terraform).
6. **Time-box and approvals:** note the start time and the cost approval.
7. **Production extras this runbook does not cover:** a deeper health check (reads through the API), point-in-time recovery, alarms in both regions, ownership of orders keyed on the Google identity (not the Cognito `sub`, which differs per pool), moving the Google consent screen out of Testing mode, and **evaluating Cognito's own [multi-Region replication](https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-multi-region.html)** (Essentials or Plus plan, a multi-Region KMS key, add-on costs; secondary pools cannot create users and have no TOTP MFA). If you move to it the tests change: the replica starts `INACTIVE` and must be activated, failover is driven by a Route 53 health check on the pool's domain, and the user pool ID is shared, so repeat the cross-region token checks (T6) and the failover test against the replica.

## 10. Troubleshooting: every problem met so far

| Symptom | Cause | Fix |
|---|---|---|
| `Error: No configuration files` on apply | Ran from the wrong folder | `cd terraform/environments/dev` first |
| `Error acquiring the state lock` | A previous apply is still alive (paused with Ctrl+Z, waiting at the prompt, or running in another terminal) | Find it (`jobs`, `ps aux \| grep "[t]erraform apply"`), `fg %N` and answer the prompt, or Ctrl+C. **Never** `-lock=false`; use `force-unlock` only when you are certain no apply is running |
| `kill %1: no such job` | Wrong job number | `jobs` shows the number; `fg %N` first, then Ctrl+C |
| Apply failed partway with `UnrecognizedClientException ... security token invalid` | The SSO session expired during a long apply | `ssologin`, then re-run the same apply (it continues; nothing billable existed yet in the first run) |
| The guard holds the placeholder or a typo | The allow-list variable was wrong at apply time | Fix `TF_VAR_allowed_emails`, re-apply (2 changes in two regions), check with B2's hash command |
| Sign-in "refused to connect" at `localhost:8765` | Nothing was listening: the script had exited (one callback only), timed out (5 minutes), the terminal was closed, or an old or used link was opened | Run the script again for a **new** link; keep the terminal open; never reuse or reload a callback link. WSL2 networking is not the cause |
| `Token request refused: ... PreTokenGeneration failed ... Sign-in is not permitted` | The account that signed in is **not on the allow-list** (often the browser reused another Google session) | Use `--private` and type the allowed address. Compare hashes (A3) to see which account signed in |
| The script opened my normal browser | Old behaviour | Use `--private`; the script no longer opens a normal window by default |
| `redirect_uri_mismatch` from Google | The redirect URI in Google does not match exactly (prefix, region, a trailing slash) or has not propagated | Fix it in the OAuth client; wait a few minutes |
| "Access blocked" from Google | The address is not a test user, or the consent screen is not External/Testing | Add it under Test users |
| 401 on a route that exists | No token, a garbage token, an expired one (about 60 minutes), or a token from a pool the API does not trust | `--refresh` or sign in again. With one region on, the second API does not exist |
| 404 on `GET /orders-via-lambda/x` | **This is success**: the token was accepted and the order does not exist | Nothing |
| `Missing Authentication Token` on `/` or on `GET /orders` | No such route and method | Use `/health`, `POST /orders`, `GET /orders/{id}`, `GET /orders-via-lambda/{id}` |
| `federated-checks.sh` printed `Output "dr_create_order_url" not found` | Terraform does not store null outputs; the second region is off | Fixed in the script (a missing output counts as null); the Part A checks then run for the primary only |
| Domain prefix error at apply | Prefix taken in that region, or the name contains `aws`, `amazon` or `cognito` | Choose another and update the Google redirect URIs |

## 11. Results of the first run (2026-10-10 and 11)

| Test | Result |
|---|---|
| T2 allowed address, one region | Passed: token from the primary pool, federated, lasts about an hour; guard logged `allow` for sign-up, sign-in and refresh |
| T3 test user not on the list | Passed: guard `deny` at sign-up, Lambda error count 1, **no user created** |
| T4 lockout | Passed: refresh refused with `PreTokenGeneration failed ... Sign-in is not permitted` (guard `deny TokenGeneration_RefreshTokens`) |
| T5 old token after removal | Still accepted (API returned 404, accepted): confirmed limitation |
| T6 each pool's token on each API | 4 of 4 accepted (Virginia pool on the Oregon API and Oregon pool on the Virginia API) |
| T7 replication through the API | Readable in the other region on the first poll after the write |
| T8 refresh in each region | Allowed address succeeded |
| T9 guard logs | Decision and trigger only; no email (0 `@` characters) |
| T10 switch off | All five switches false; no replica, health checks, certificates, custom domains, second-region resources or IAM roles left; the zone back to its original records; the website 200; `terraform plan` showing no changes |

Time lost to avoidable mistakes (all covered above): a placeholder address applied once, a normal browser reusing another Google session, reloading a used
callback link, a paused apply holding the lock, and an apply started from the wrong folder. Cost: the Google sign-in alone was free; the two-region stack was on
for about 30 minutes (estimated at a few cents; the bill was not read).
