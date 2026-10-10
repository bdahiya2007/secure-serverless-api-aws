#!/usr/bin/env bash
# Behaviour checks for the API Gateway stage cache (run with enable_api_cache=true): hits against the first miss, a missing or
# bad token still gets 401, ids are not mixed up, responses are shared between users, a write is not visible until the TTL ends
# or the cache is flushed, Cache-Control: max-age=0 is ignored, and 404s are cached.
# Creates two temporary Cognito users and order rows and ALWAYS removes them on exit. Needs: AWS credentials, terraform,
# curl, openssl, python3. FLUSH_WAIT (default 60) is how long to wait after a flush; it takes about 50 s to take effect.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)/terraform/environments/dev"
POOL=$(terraform output -raw user_pool_id); CLIENT=$(terraform output -raw user_pool_client_id); URL=$(terraform output -raw create_order_url); BASE=${URL%/orders}; API=$(terraform output -raw rest_api_id)
RUN=$(openssl rand -hex 3); PFX="cch-$RUN"; E1="cch1-$RUN@example.com"; E2="cch2-$RUN@example.com"; PW="Aa1!$(openssl rand -hex 12)"
cleanup() { python3 - "$PFX" <<'PY'
import json,subprocess,sys
p=sys.argv[1]; aws=lambda *a: subprocess.run(["aws",*a],capture_output=True,text=True,check=True).stdout
k=json.loads(aws("dynamodb","scan","--table-name","Orders","--filter-expression","begins_with(orderId, :p)","--expression-attribute-values",json.dumps({":p":{"S":p}}),"--projection-expression","orderId,itemId","--query","Items","--output","json") or "[]")
for i in range(0,len(k),25): aws("dynamodb","batch-write-item","--request-items",json.dumps({"Orders":[{"DeleteRequest":{"Key":x}} for x in k[i:i+25]]}))
print(f"cleanup: deleted {len(k)} rows")
PY
for e in "$E1" "$E2"; do aws cognito-idp admin-delete-user --user-pool-id "$POOL" --username "$e" >/dev/null 2>&1; done
echo "cleanup: Orders rows left=$(aws dynamodb scan --table-name Orders --select COUNT --query Count --output text), users left=$(aws cognito-idp list-users --user-pool-id "$POOL" --query 'length(Users)' --output text)"; }
trap cleanup EXIT
mkuser() { aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$1" --user-attributes Name=email,Value="$1" Name=email_verified,Value=true --message-action SUPPRESS >/dev/null; aws cognito-idp admin-set-user-password --user-pool-id "$POOL" --username "$1" --password "$PW" --permanent; aws cognito-idp initiate-auth --client-id "$CLIENT" --auth-flow USER_PASSWORD_AUTH --auth-parameters USERNAME="$1",PASSWORD="$PW" --query AuthenticationResult.IdToken --output text; }
T1=$(mkuser "$E1"); T2=$(mkuser "$E2")
post() { curl -s -o /dev/null -m 20 -X POST "$URL" -H "Content-Type: application/json" -H "Authorization: $T1" -d "{\"orderId\":\"$1\",\"itemId\":\"$2\",\"quantity\":$3}"; }
# get <token or -> <path> [extra curl args...]  ->  prints "HTTP code | items | qty | ms"
get() { local tok=$1 path=$2; shift 2; local -a h=(); [ "$tok" != "-" ] && h=(-H "Authorization: $tok"); curl -s -m 25 -w '\n%{http_code} %{time_total}' "${h[@]}" "$@" "$BASE/$path" | python3 -c "
import sys,json
raw=sys.stdin.read(); body,_,tail=raw.rpartition('\n'); code,t=tail.split()
try: j=json.loads(body); n=j.get('itemCount','-'); q=','.join(str(i.get('quantity')) for i in j.get('items',[])) or '-'
except Exception: n='-'; q='-'
print(f'HTTP {code}  items={n} qty=[{q}]  {float(t)*1000:.0f} ms')"; }
A="$PFX-A"; D="$PFX-D"; B="$PFX-B"; flush() { aws apigateway flush-stage-cache --rest-api-id "$API" --stage-name dev >/dev/null; sleep "${FLUSH_WAIT:-60}"; }
post "$A" i-1 1; post "$D" i-1 7; sleep 1; flush
for R in orders orders-via-lambda; do
 echo; echo "################ route: GET /$R/{id}"
 echo "-- hits: 1 miss then repeats (ms)"; printf 'miss : '; get "$T1" "$R/$A"; for i in 1 2 3 4 5 6 7; do get "$T1" "$R/$A" | sed 's/.*  //'; done | tr '\n' ' '; echo
 echo "-- security: the cache must not serve a cached order to a caller without a valid token"
 printf 'no token      : '; get - "$R/$A"; printf 'bad token     : '; get "not.a.token" "$R/$A"
 echo "-- ids must not be mixed up (A has quantity 1, D has quantity 7)"
 printf 'order A       : '; get "$T1" "$R/$A"; printf 'order D       : '; get "$T1" "$R/$D"; printf 'order A again : '; get "$T1" "$R/$A"
 echo "-- shared between users: a second user reads A (cached by user 1)"; printf 'user 2 reads A: '; get "$T2" "$R/$A"
done
echo; echo "################ staleness (both routes cached A with 1 item; now add item i-2)"
post "$A" i-2 1
for R in orders orders-via-lambda; do printf '%-18s read A after write           : ' "$R"; get "$T1" "$R/$A"; printf '%-18s with Cache-Control max-age=0: ' "$R"; get "$T1" "$R/$A" -H "Cache-Control: max-age=0"; done
echo "-- flushing the stage cache"; flush
for R in orders orders-via-lambda; do printf '%-18s read A after flush           : ' "$R"; get "$T1" "$R/$A"; done
echo; echo "################ negative caching (is a 404 cached?)"
for R in orders orders-via-lambda; do printf '%-18s B missing                   : ' "$R"; get "$T1" "$R/$B"; done
post "$B" i-1 1; sleep 1
for R in orders orders-via-lambda; do printf '%-18s B after it was created       : ' "$R"; get "$T1" "$R/$B"; done
flush; for R in orders orders-via-lambda; do printf '%-18s B after flush             : ' "$R"; get "$T1" "$R/$B"; done
