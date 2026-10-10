#!/usr/bin/env bash
# Behaviour checks for DAX (run with enable_dax=true): first request after joining the VPC, read-after-write on a new order,
# a stale list, negative caching (a cached 404) and repeated reads. Waits 62 s for the 60 s query TTL.
# If the API cache is also on, the "direct read" is cached too and is NOT a ground truth; run this with the API cache off.
# Creates a temporary Cognito user and order rows and ALWAYS removes them on exit. Needs: AWS credentials, terraform,
# curl, openssl, python3.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)/terraform/environments/dev"
POOL=$(terraform output -raw user_pool_id); CLIENT=$(terraform output -raw user_pool_client_id); URL=$(terraform output -raw create_order_url); BASE=${URL%/orders}
RUN=$(openssl rand -hex 3); EMAIL="daxt-$RUN@example.com"; PW="Aa1!$(openssl rand -hex 12)"; PFX="daxt-$RUN"
cleanup() { python3 - "$PFX" <<'PY'
import json,subprocess,sys
p=sys.argv[1]; aws=lambda *a: subprocess.run(["aws",*a],capture_output=True,text=True,check=True).stdout
k=json.loads(aws("dynamodb","scan","--table-name","Orders","--filter-expression","begins_with(orderId, :p)","--expression-attribute-values",json.dumps({":p":{"S":p}}),"--projection-expression","orderId,itemId","--query","Items","--output","json") or "[]")
for i in range(0,len(k),25): aws("dynamodb","batch-write-item","--request-items",json.dumps({"Orders":[{"DeleteRequest":{"Key":x}} for x in k[i:i+25]]}))
print(f"cleanup: deleted {len(k)} rows")
PY
aws cognito-idp admin-delete-user --user-pool-id "$POOL" --username "$EMAIL" >/dev/null 2>&1; echo "cleanup: Orders rows left=$(aws dynamodb scan --table-name Orders --select COUNT --query Count --output text), users left=$(aws cognito-idp list-users --user-pool-id "$POOL" --query 'length(Users)' --output text)"; }
trap cleanup EXIT
aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$EMAIL" --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true --message-action SUPPRESS >/dev/null
aws cognito-idp admin-set-user-password --user-pool-id "$POOL" --username "$EMAIL" --password "$PW" --permanent
TOK=$(aws cognito-idp initiate-auth --client-id "$CLIENT" --auth-flow USER_PASSWORD_AUTH --auth-parameters USERNAME="$EMAIL",PASSWORD="$PW" --query AuthenticationResult.IdToken --output text)
post() { curl -s -o /dev/null -m 20 -X POST "$URL" -H "Content-Type: application/json" -H "Authorization: $TOK" -d "{\"orderId\":\"$1\",\"itemId\":\"$2\",\"quantity\":1}"; }
get()  { curl -s -m 25 -w '\n%{http_code} %{time_total}' -H "Authorization: $TOK" "$BASE/$1"; }
cnt()  { python3 -c "
import sys,json
raw=sys.stdin.read(); body,_,tail=raw.rpartition('\n'); code,t=tail.split()
try: n=json.loads(body).get('itemCount','-')
except Exception: n='-'
print(f'HTTP {code}  items={n}  {float(t)*1000:.0f} ms')"; }
A="$PFX-A"; B="$PFX-B"

echo "== first request after the Lambda joined the VPC and DAX (cold start incl. DAX connection)"
post "$A" i-1; sleep 1
printf 'Lambda read (DAX), first request:     '; get "orders-via-lambda/$A" | cnt
echo; echo "== T1 read-after-write on a fresh order (no cache entry yet)"
post "$PFX-C" i-1; printf 'POST then immediate Lambda read (DAX): '; get "orders-via-lambda/$PFX-C" | cnt

echo; echo "== T2 stale list: order A is now cached with 1 item; add a 2nd item and read straight away"
printf 'before:  Lambda read (DAX):            '; get "orders-via-lambda/$A" | cnt
printf 'before:  direct read (no DAX):        '; get "orders/$A" | cnt
echo "-- negative caching setup: read an order that does not exist yet"
printf 'B (missing) Lambda read (DAX):         '; get "orders-via-lambda/$B" | cnt
post "$A" i-2; post "$B" i-1; echo "-- POSTed item i-2 to A and item i-1 to B"
printf 'after:   Lambda read of A (DAX):       '; get "orders-via-lambda/$A" | cnt
printf 'after:   direct read of A (no DAX):    '; get "orders/$A" | cnt
printf 'after:   Lambda read of B (DAX):       '; get "orders-via-lambda/$B" | cnt
printf 'after:   direct read of B (no DAX):    '; get "orders/$B" | cnt
echo; echo "-- waiting 62 s (the DAX query TTL is 60 s)"; sleep 62
printf 'later:   Lambda read of A (DAX):       '; get "orders-via-lambda/$A" | cnt
printf 'later:   Lambda read of B (DAX):       '; get "orders-via-lambda/$B" | cnt
echo; echo "== repeated reads of one cached order (DAX hits), ms:"
for i in 1 2 3 4 5 6; do get "orders-via-lambda/$A" | cnt | sed 's/.*  //'; done | tr '\n' ' '; echo
