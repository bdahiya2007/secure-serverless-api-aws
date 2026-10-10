#!/usr/bin/env bash
# Like-for-like latency comparison of the two ways the API reads an order:
#   GET /orders/{orderId}              API Gateway -> DynamoDB (direct integration, VTL templates)
#   GET /orders-via-lambda/{orderId}   API Gateway -> Lambda -> DynamoDB
# Both run the same strongly consistent Query for the same order. Requests are INTERLEAVED (direct, Lambda, gateway
# floor, repeat) so network drift affects each path equally. The "gateway floor" is an unauthenticated request that
# API Gateway rejects with 401, which shows the cost of the round trip alone.
#
# Creates a temporary Cognito user and order rows, and ALWAYS removes them on exit.
# Needs: AWS credentials (aws sso login), terraform, curl, openssl, python3. Cost: a few hundred API requests.
# ROUNDS (default 50) sets the number of requests per path. Each curl opens a new connection, so the absolute numbers
# include TCP and TLS setup; compare the paths with each other, not with a browser or a same-region client.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)/terraform/environments/dev"
ROUNDS=${ROUNDS:-50}

POOL=$(terraform output -raw user_pool_id)
CLIENT=$(terraform output -raw user_pool_client_id)
URL=$(terraform output -raw create_order_url)
BASE=${URL%/orders}

RUN=$(openssl rand -hex 4)
EMAIL="cmp-${RUN}@example.com"
PASSWORD="Aa1!$(openssl rand -hex 12)"
ORDER="cmp-${RUN}"
WORK=$(mktemp -d)

cleanup() {
  echo >&2; echo "Cleaning up..." >&2
  python3 - "$ORDER" <<'PY' >&2 || true
import json, subprocess, sys
prefix = sys.argv[1]
def aws(*a): return subprocess.run(["aws", *a], capture_output=True, text=True, check=True).stdout
keys = json.loads(aws("dynamodb", "scan", "--table-name", "Orders", "--filter-expression", "begins_with(orderId, :p)",
    "--expression-attribute-values", json.dumps({":p": {"S": prefix}}), "--projection-expression", "orderId,itemId",
    "--query", "Items", "--output", "json") or "[]")
for i in range(0, len(keys), 25):
    aws("dynamodb", "batch-write-item", "--request-items",
        json.dumps({"Orders": [{"DeleteRequest": {"Key": k}} for k in keys[i:i + 25]]}))
print(f"  deleted {len(keys)} order rows")
PY
  aws cognito-idp admin-delete-user --user-pool-id "$POOL" --username "$EMAIL" >/dev/null 2>&1 || true
  echo "  Orders rows left:   $(aws dynamodb scan --table-name Orders --select COUNT --query Count --output text)" >&2
  echo "  Cognito users left: $(aws cognito-idp list-users --user-pool-id "$POOL" --query 'length(Users)' --output text)" >&2
  rm -rf "$WORK"
}
trap cleanup EXIT

aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$EMAIL" \
  --user-attributes Name="email",Value="$EMAIL" Name="email_verified",Value="true" --message-action SUPPRESS >/dev/null
aws cognito-idp admin-set-user-password --user-pool-id "$POOL" --username "$EMAIL" --password "$PASSWORD" --permanent
TOKEN=$(aws cognito-idp initiate-auth --client-id "$CLIENT" --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters USERNAME="$EMAIL",PASSWORD="$PASSWORD" --query AuthenticationResult.IdToken --output text)

# One order with three items, so both paths read the same data.
for item in i-1 i-2 i-3; do
  curl -sS -o /dev/null -m 20 -X POST "$URL" -H "Content-Type: application/json" -H "Authorization: $TOKEN" \
    -d "{\"orderId\":\"$ORDER\",\"itemId\":\"$item\",\"quantity\":2,\"price\":9.99}"
done

time_of() { curl -s -o /dev/null -w '%{time_total}\n' -m 20 "$@"; }
direct()  { time_of -H "Authorization: $TOKEN" "$BASE/orders/$ORDER"; }
via_lambda()    { time_of -H "Authorization: $TOKEN" "$BASE/orders-via-lambda/$ORDER"; }
floor_()  { time_of "$BASE/orders/$ORDER"; }   # no token: rejected by the authorizer, no backend work

echo "Warming up both paths (the first Lambda request is a cold start and is excluded)..." >&2
for _ in 1 2 3 4 5; do direct >/dev/null; via_lambda >/dev/null; done

echo "Measuring $ROUNDS interleaved rounds..." >&2
for _ in $(seq 1 "$ROUNDS"); do
  direct >>"$WORK/direct.txt"; via_lambda >>"$WORK/lambda.txt"; floor_ >>"$WORK/floor.txt"
done

python3 - "$WORK" "$ROUNDS" <<'PY'
import statistics as st, sys
work, n = sys.argv[1], sys.argv[2]
def stats(name):
    v = sorted(float(x) * 1000 for x in open(f"{work}/{name}.txt").read().split())
    return len(v), st.median(v), v[max(0, int(0.9 * len(v)) - 1)], v[0], v[-1]
rows = [("API Gateway only (401, no backend)", stats("floor")),
        ("GET /orders/{id}: direct DynamoDB integration", stats("direct")),
        ("GET /orders-via-lambda/{id}: Lambda + DynamoDB", stats("lambda"))]
print(f"\n| Path | n | Median (ms) | p90 (ms) | Min (ms) | Max (ms) | Over gateway floor (median) |")
print("|---|---|---|---|---|---|---|")
floor = rows[0][1][1]
for label, (k, med, p90, lo, hi) in rows:
    over = "" if label.startswith("API Gateway only") else f"+{med - floor:.0f} ms"
    print(f"| {label} | {k} | {med:.0f} | {p90:.0f} | {lo:.0f} | {hi:.0f} | {over} |")
d, l = rows[1][1][1], rows[2][1][1]
print(f"\nLambda minus direct (median): {l - d:+.0f} ms")
PY
