#!/usr/bin/env bash
# Checks CORS on the deployed API (cors_allowed_origins must be set, so the browser front end can call it):
#   1 preflight (OPTIONS) on each route: an allowed origin gets the allow headers, a disallowed one does not
#   2 errors that API Gateway itself produces (401 without a token) carry the allow header for the FIRST origin
#   3 real calls with a token (404, 400, 201, 200 from both the Lambda and the direct routes) echo an allowed origin only
# Creates one temporary Cognito user and order rows, and ALWAYS removes them on exit. Needs: AWS credentials, terraform, curl,
# openssl, python3. Cost: about 40 API requests. ALLOWED_ORIGIN overrides the origin tested (default: the first one configured).
set -uo pipefail
cd "$(git rev-parse --show-toplevel)/terraform/environments/dev"
ORIGINS=$(terraform output -json cors_allowed_origins 2>/dev/null || echo '[]')
FIRST=$(echo "$ORIGINS" | python3 -c "import sys,json; o=json.load(sys.stdin); print(o[0] if o else '')")
[ -z "$FIRST" ] && { echo "CORS is not enabled (cors_allowed_origins is empty). Apply with -var 'cors_allowed_origins=[...]' first."; exit 1; }
OK_ORIGIN=${ALLOWED_ORIGIN:-$FIRST}; BAD_ORIGIN="https://not-allowed.example.test"
POOL=$(terraform output -raw user_pool_id); CLIENT=$(terraform output -raw user_pool_client_id)
URL=$(terraform output -raw create_order_url); BASE=${URL%/orders}
RUN=$(openssl rand -hex 3); EMAIL="cors-$RUN@example.com"; PW="Aa1!$(openssl rand -hex 12)"; PFX="cors-$RUN"
cleanup() {
  python3 - "$PFX" <<'PY'
import json,subprocess,sys
p=sys.argv[1]; aws=lambda *a: subprocess.run(["aws",*a],capture_output=True,text=True,check=True).stdout
k=json.loads(aws("dynamodb","scan","--table-name","Orders","--filter-expression","begins_with(orderId, :p)","--expression-attribute-values",json.dumps({":p":{"S":p}}),"--projection-expression","orderId,itemId","--query","Items","--output","json") or "[]")
for i in range(0,len(k),25): aws("dynamodb","batch-write-item","--request-items",json.dumps({"Orders":[{"DeleteRequest":{"Key":x}} for x in k[i:i+25]]}))
print(f"cleanup: deleted {len(k)} order rows")
PY
  aws cognito-idp admin-delete-user --user-pool-id "$POOL" --username "$EMAIL" >/dev/null 2>&1
  echo "cleanup: users left=$(aws cognito-idp list-users --user-pool-id "$POOL" --query 'length(Users)' --output text)"
}
trap cleanup EXIT
aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$EMAIL" --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true --message-action SUPPRESS >/dev/null
aws cognito-idp admin-set-user-password --user-pool-id "$POOL" --username "$EMAIL" --password "$PW" --permanent
TOK=$(aws cognito-idp initiate-auth --client-id "$CLIENT" --auth-flow USER_PASSWORD_AUTH --auth-parameters USERNAME="$EMAIL",PASSWORD="$PW" --query AuthenticationResult.IdToken --output text)

PASS=0; FAIL=0
# req <expected status> <label> <expected allow-origin or "-" for none> <curl args...>   prints one line, counts pass/fail
req() {
  local want_status=$1 label=$2 want_origin=$3; shift 3
  local hdr; hdr=$(curl -s -m 25 -D - -o /dev/null "$@")
  local status; status=$(echo "$hdr" | head -1 | awk '{print $2}')
  local got; got=$(echo "$hdr" | tr -d '\r' | awk -F': ' 'tolower($1)=="access-control-allow-origin"{print $2}')
  local vary; vary=$(echo "$hdr" | tr -d '\r' | awk -F': ' 'tolower($1)=="vary"{print $2}')
  local ok=1
  [ "$status" = "$want_status" ] || ok=0
  if [ "$want_origin" = "-" ]; then [ -z "$got" ] || ok=0; else [ "$got" = "$want_origin" ] || ok=0; fi
  case "$vary" in *Origin*) ;; *) ok=0;; esac
  if [ $ok = 1 ]; then PASS=$((PASS+1)); echo "  ok   $label -> $status, allow-origin=${got:--}"; else FAIL=$((FAIL+1)); echo "  FAIL $label -> status $status (want $want_status), allow-origin='${got:--}' (want '$want_origin'), vary='$vary'"; fi
}
preflight() { # <label> <path> <method> <origin> <expected allow-origin>
  req 200 "$1" "$5" -X OPTIONS -H "Origin: $4" -H "Access-Control-Request-Method: $3" -H "Access-Control-Request-Headers: authorization,content-type" "$BASE$2"
}
echo "origin tested: allowed=$OK_ORIGIN, disallowed=$BAD_ORIGIN"
echo "== 1 preflight"
preflight "POST /orders (allowed origin)"                      /orders                 POST "$OK_ORIGIN"  "$OK_ORIGIN"
preflight "GET /orders/{id} (allowed origin)"                  /orders/x               GET  "$OK_ORIGIN"  "$OK_ORIGIN"
preflight "GET /orders-via-lambda/{id} (allowed origin)"       /orders-via-lambda/x    GET  "$OK_ORIGIN"  "$OK_ORIGIN"
preflight "POST /orders (DISALLOWED origin gets no header)"    /orders                 POST "$BAD_ORIGIN" "-"
hdr=$(curl -s -m 25 -D - -o /dev/null -X OPTIONS -H "Origin: $OK_ORIGIN" -H "Access-Control-Request-Method: POST" "$BASE/orders" | tr -d '\r')
echo "$hdr" | grep -qi '^access-control-allow-headers:.*authorization' && echo "  ok   allow-headers includes Authorization" || { FAIL=$((FAIL+1)); echo "  FAIL allow-headers lacks Authorization"; }
echo "$hdr" | grep -qi '^access-control-allow-methods:.*POST' && echo "  ok   allow-methods includes POST" || { FAIL=$((FAIL+1)); echo "  FAIL allow-methods lacks POST"; }
echo "== 2 errors API Gateway produces itself"
req 401 "GET /orders/{id} without a token (first origin)" "$FIRST" -H "Origin: $FIRST" "$BASE/orders/x"
echo "== 3 real calls with a token"
req 404 "direct read, missing order, allowed origin"   "$OK_ORIGIN" -H "Authorization: $TOK" -H "Origin: $OK_ORIGIN" "$BASE/orders/$PFX-missing"
req 404 "direct read, missing order, DISALLOWED origin" "-"         -H "Authorization: $TOK" -H "Origin: $BAD_ORIGIN" "$BASE/orders/$PFX-missing"
req 404 "Lambda read, missing order, allowed origin"   "$OK_ORIGIN" -H "Authorization: $TOK" -H "Origin: $OK_ORIGIN" "$BASE/orders-via-lambda/$PFX-missing"
req 400 "Lambda read, invalid id, allowed origin"      "$OK_ORIGIN" -H "Authorization: $TOK" -H "Origin: $OK_ORIGIN" "$BASE/orders-via-lambda/bad%20id"
req 400 "write, invalid body (API validation), first origin" "$FIRST" -X POST -H "Authorization: $TOK" -H "Origin: $FIRST" -H "Content-Type: application/json" -d '{}' "$URL"
req 201 "write, valid, allowed origin"                 "$OK_ORIGIN" -X POST -H "Authorization: $TOK" -H "Origin: $OK_ORIGIN" -H "Content-Type: application/json" -d "{\"orderId\":\"$PFX-A\",\"itemId\":\"i-1\",\"quantity\":1}" "$URL"
req 409 "write, duplicate, allowed origin"             "$OK_ORIGIN" -X POST -H "Authorization: $TOK" -H "Origin: $OK_ORIGIN" -H "Content-Type: application/json" -d "{\"orderId\":\"$PFX-A\",\"itemId\":\"i-1\",\"quantity\":1}" "$URL"
req 200 "direct read, found, allowed origin"           "$OK_ORIGIN" -H "Authorization: $TOK" -H "Origin: $OK_ORIGIN" "$BASE/orders/$PFX-A"
req 200 "Lambda read, found, allowed origin"           "$OK_ORIGIN" -H "Authorization: $TOK" -H "Origin: $OK_ORIGIN" "$BASE/orders-via-lambda/$PFX-A"
echo; echo "result: $PASS passed, $FAIL failed"; [ "$FAIL" = 0 ]
