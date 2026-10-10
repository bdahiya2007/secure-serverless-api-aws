#!/usr/bin/env bash
# End-to-end smoke test for the deployed orders API.
#
# Creates a temporary Cognito user and a few order rows, calls POST /orders, GET /orders/{orderId}
# (the direct DynamoDB integration) and GET /orders-via-lambda/{orderId} (the Lambda read) for the success and failure cases, then ALWAYS removes the user and the rows (even if a check fails or you press Ctrl+C).
# Needs: AWS credentials (aws sso login), terraform, curl, openssl, python3.
# Cost: a handful of API requests; everything stays inside the free tiers.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/terraform/environments/dev"

POOL=$(terraform output -raw user_pool_id)
CLIENT=$(terraform output -raw user_pool_client_id)
URL=$(terraform output -raw create_order_url)

RUN=$(openssl rand -hex 4)
EMAIL="smoke-${RUN}@example.com"
PASSWORD="Aa1!$(openssl rand -hex 12)"
ORDER="smoke-${RUN}"
PASS=0
FAIL=0

cleanup() {
  echo
  echo "Cleaning up..."
  aws dynamodb delete-item --table-name Orders \
    --key "{\"orderId\":{\"S\":\"${ORDER}\"},\"itemId\":{\"S\":\"i-1\"}}" >/dev/null 2>&1 || true
  aws cognito-idp admin-delete-user --user-pool-id "$POOL" --username "$EMAIL" >/dev/null 2>&1 || true
  echo "  Orders rows left:  $(aws dynamodb scan --table-name Orders --select COUNT --query Count --output text)"
  echo "  Cognito users left: $(aws cognito-idp list-users --user-pool-id "$POOL" --query 'length(Users)' --output text)"
}
trap cleanup EXIT

aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$EMAIL" \
  --user-attributes Name="email",Value="$EMAIL" Name="email_verified",Value="true" \
  --message-action SUPPRESS >/dev/null
aws cognito-idp admin-set-user-password --user-pool-id "$POOL" --username "$EMAIL" \
  --password "$PASSWORD" --permanent

AUTH=$(aws cognito-idp initiate-auth --client-id "$CLIENT" --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters USERNAME="$EMAIL",PASSWORD="$PASSWORD" --output json)
field() { python3 -c "import sys,json; print(json.load(sys.stdin)['AuthenticationResult']['$1'])" <<<"$AUTH"; }
ID_TOKEN=$(field IdToken)
ACCESS_TOKEN=$(field AccessToken)

# expect <description> <expected HTTP status> <token or "-"> <JSON body>
expect() {
  local desc=$1 want=$2 token=$3 body=$4 got
  local -a auth=()
  [ "$token" != "-" ] && auth=(-H "Authorization: $token")
  got=$(curl -sS -o /dev/null -w '%{http_code}' -m 20 -X POST "$URL" \
    -H "Content-Type: application/json" "${auth[@]}" -d "$body")
  if [ "$got" = "$want" ]; then
    printf '  PASS  %-52s HTTP %s\n' "$desc" "$got"; PASS=$((PASS + 1))
  else
    printf '  FAIL  %-52s expected %s, got %s\n' "$desc" "$want" "$got"; FAIL=$((FAIL + 1))
  fi
}

# expect_get <description> <expected HTTP status> <token or "-"> <path under the API stage, URL-encoded> [text the body must contain]
expect_get() {
  local desc=$1 want=$2 token=$3 path=$4 needle=${5:-} out got body
  local -a auth=()
  [ "$token" != "-" ] && auth=(-H "Authorization: $token")
  out=$(curl -sS -w '\n%{http_code}' -m 20 "${auth[@]}" "${BASE_URL}/${path}")
  got=${out##*$'\n'}
  body=${out%$'\n'*}
  if [ "$got" = "$want" ] && { [ -z "$needle" ] || grep -qF -- "$needle" <<<"$body"; }; then
    printf '  PASS  %-52s HTTP %s\n' "$desc" "$got"; PASS=$((PASS + 1))
  else
    printf '  FAIL  %-52s expected %s%s, got %s\n' "$desc" "$want" "${needle:+ containing $needle}" "$got"; FAIL=$((FAIL + 1))
  fi
}

BASE_URL=${URL%/orders}   # the stage URL; read paths are appended to it

echo "Calling ${URL}"
VALID="{\"orderId\":\"${ORDER}\",\"itemId\":\"i-1\",\"quantity\":2,\"price\":9.99}"
expect "valid order is saved"                         201 "$ID_TOKEN"     "$VALID"
expect "same order again is rejected (no overwrite)"  409 "$ID_TOKEN"     "$VALID"
expect "no token"                                     401 "-"             "$VALID"
expect "access token instead of ID token"             401 "$ACCESS_TOKEN" "$VALID"
expect "missing orderId and an extra field"           400 "$ID_TOKEN"     '{"itemId":"i-1","extra":1}'
expect "malformed JSON"                               400 "$ID_TOKEN"     '{not json'

# Reads go straight from API Gateway to DynamoDB (no Lambda).
expect_get "read the order back (200, item present)"      200 "$ID_TOKEN" "orders/$ORDER" '"itemId": "i-1"'
expect_get "read keeps numbers as numbers"                200 "$ID_TOKEN" "orders/$ORDER" '"quantity": 2'
expect_get "unknown order"                                404 "$ID_TOKEN" "orders/no-such-${RUN}"
expect_get "id with a quote is handled safely"            404 "$ID_TOKEN" 'orders/a%22b'
expect_get "read without a token"                         401 "-"         "orders/$ORDER"

# The same read done by a Lambda (for comparison). Note the differences: compact JSON, a "truncated" flag, and 400
# (not 404) for an invalid id, because the Lambda validates ids with an allow-list.
expect_get "Lambda read: order with its items"            200 "$ID_TOKEN" "orders-via-lambda/$ORDER" '"itemId":"i-1"'
expect_get "Lambda read: numbers, and truncated flag"     200 "$ID_TOKEN" "orders-via-lambda/$ORDER" '"truncated":false'
expect_get "Lambda read: unknown order"                   404 "$ID_TOKEN" "orders-via-lambda/no-such-${RUN}"
expect_get "Lambda read: invalid id is rejected"          400 "$ID_TOKEN" 'orders-via-lambda/a%22b'
expect_get "Lambda read: no token"                        401 "-"         "orders-via-lambda/$ORDER"

echo
echo "Result: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
