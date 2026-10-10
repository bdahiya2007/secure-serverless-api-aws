#!/usr/bin/env bash
# Checks for the multi-region (global table, active/active) setup. Run with enable_multi_region=true applied.
#   API_DOMAIN=api.example.com scripts/demo/multi-region-checks.sh
# 1 health route in both regions   2 a token from the one Cognito pool is accepted by the second region's API
# 3 replication primary -> second region and back, with the lag   4 a write conflict on one item (last writer wins)
# 5 the custom domain answers (which region?)   6 optional failover simulation (SIMULATE_FAILOVER=1): the health check of the
#   region that is answering is INVERTED (forced to fail), DNS moves to the other region, then it is put back (always restored on exit).
# Creates one temporary Cognito user and order rows (deleted on exit). Needs: AWS credentials, terraform, curl, dig, openssl,
# python3. Cost: a few hundred API requests.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)/terraform/environments/dev"
: "${API_DOMAIN:?set API_DOMAIN to the multi-region name, for example api.example.com}"
POOL=$(terraform output -raw user_pool_id); CLIENT=$(terraform output -raw user_pool_client_id)
P_URL=$(terraform output -raw create_order_url); P_BASE=${P_URL%/orders}
D_URL=$(terraform output -json dr_create_order_url | tr -d '"'); D_BASE=${D_URL%/orders}
[ "$D_URL" = "null" ] && { echo "multi-region is not on (dr_create_order_url is null)"; exit 1; }
P_REGION=$(aws configure get region 2>/dev/null || echo us-east-1); P_REGION=${AWS_REGION:-$P_REGION}
D_REGION=$(echo "$D_BASE" | sed 's/.*execute-api\.\([a-z0-9-]*\)\.amazonaws.*/\1/')
HC=$(terraform output -json multi_region_health_check_ids)
RUN=$(openssl rand -hex 3); EMAIL="mr-$RUN@example.com"; PW="Aa1!$(openssl rand -hex 12)"; PFX="mr-$RUN"
revert_hc() { for id in $(echo "$HC" | python3 -c "import sys,json; print(' '.join(json.load(sys.stdin).values()))"); do aws route53 update-health-check --health-check-id "$id" --no-inverted >/dev/null 2>&1; done; }
cleanup() {
  revert_hc
  python3 - "$PFX" <<'PY'
import json,subprocess,sys
p=sys.argv[1]; aws=lambda *a: subprocess.run(["aws",*a],capture_output=True,text=True,check=True).stdout
k=json.loads(aws("dynamodb","scan","--table-name","Orders","--filter-expression","begins_with(orderId, :p)","--expression-attribute-values",json.dumps({":p":{"S":p}}),"--projection-expression","orderId,itemId","--query","Items","--output","json") or "[]")
for i in range(0,len(k),25): aws("dynamodb","batch-write-item","--request-items",json.dumps({"Orders":[{"DeleteRequest":{"Key":x}} for x in k[i:i+25]]}))
print(f"cleanup: deleted {len(k)} rows (the deletes replicate to the other region)")
PY
  aws cognito-idp admin-delete-user --user-pool-id "$POOL" --username "$EMAIL" >/dev/null 2>&1
  echo "cleanup: users left=$(aws cognito-idp list-users --user-pool-id "$POOL" --query 'length(Users)' --output text); health check restored"
}
trap cleanup EXIT
aws cognito-idp admin-create-user --user-pool-id "$POOL" --username "$EMAIL" --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true --message-action SUPPRESS >/dev/null
aws cognito-idp admin-set-user-password --user-pool-id "$POOL" --username "$EMAIL" --password "$PW" --permanent
TOK=$(aws cognito-idp initiate-auth --client-id "$CLIENT" --auth-flow USER_PASSWORD_AUTH --auth-parameters USERNAME="$EMAIL",PASSWORD="$PW" --query AuthenticationResult.IdToken --output text)
post() { curl -s -o /dev/null -w '%{http_code}' -m 20 -X POST "$1/orders" -H "Content-Type: application/json" -H "Authorization: $TOK" -d "{\"orderId\":\"$2\",\"itemId\":\"$3\",\"quantity\":$4}"; }
qty() { curl -s -m 20 -H "Authorization: $TOK" "$1/orders-via-lambda/$2" | python3 -c "import sys,json
try: print(','.join(str(i.get('quantity')) for i in json.load(sys.stdin).get('items',[])) or '-')
except Exception: print('-')"; }
# wait <base> <orderId> <expected quantity list>: seconds until the order shows up, or timeout
wait_for() { local t0=$SECONDS; for i in $(seq 1 60); do [ "$(qty "$1" "$2")" = "$3" ] && { echo "$((SECONDS-t0))s (polled every ~1 s)"; return; }; sleep 0.5; done; echo "NOT seen after 30 s"; }

echo "== 1 health route (no token), both regions"
echo "primary:  $(curl -s -m 10 "$P_BASE/health")"; echo "second:   $(curl -s -m 10 "$D_BASE/health")"
echo; echo "== 2 token from the single (primary-region) Cognito pool, used on the second region's API"
echo "no token on second region:        HTTP $(curl -s -o /dev/null -w '%{http_code}' "$D_BASE/orders-via-lambda/x")   (expect 401)"
echo "valid token on second region:     HTTP $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: $TOK" "$D_BASE/orders-via-lambda/x")   (expect 404 = accepted, order not found; 401 = tokens NOT accepted)"
echo; echo "== 3 replication"
echo "POST to $P_REGION: HTTP $(post "$P_BASE" "$PFX-A" i-1 1)"; echo "  visible in $D_REGION after: $(wait_for "$D_BASE" "$PFX-A" 1)"
echo "POST to $D_REGION: HTTP $(post "$D_BASE" "$PFX-B" i-1 2)"; echo "  visible in $P_REGION after: $(wait_for "$P_BASE" "$PFX-B" 2)"
echo; echo "== 4 conflict: the same item written in both regions at the same moment (different quantities)"
post "$P_BASE" "$PFX-C" i-1 10 >/dev/null & post "$D_BASE" "$PFX-C" i-1 20 >/dev/null & wait
sleep 8
echo "after 8 s: $P_REGION sees quantity $(qty "$P_BASE" "$PFX-C"), $D_REGION sees quantity $(qty "$D_BASE" "$PFX-C")   (both must be the same: last writer wins)"
echo; echo "== 5 the custom domain ($API_DOMAIN)"
echo "DNS answers: $(dig +short "$API_DOMAIN" | tr '\n' ' ')"
echo "GET https://$API_DOMAIN/health -> $(curl -s -m 10 "https://$API_DOMAIN/health")"
echo "authenticated read through the domain: quantity $(qty "https://$API_DOMAIN" "$PFX-A")"

if [ "${SIMULATE_FAILOVER:-0}" = 1 ]; then
  # Fail the region that is answering now (the nearest one), so DNS has to move to the other. Both checks are restored on exit.
  answering() { curl -s -m 10 "https://$API_DOMAIN/health" | python3 -c "import sys,json
try: print(json.load(sys.stdin).get('region','?'))
except Exception: print('?')"; }
  FROM=$(answering); TO=$D_REGION; [ "$FROM" = "$D_REGION" ] && TO=$P_REGION
  echo; echo "== 6 failover simulation: $FROM is answering; force its health check to FAIL (inverted); restored on exit"
  PID=$(echo "$HC" | python3 -c "import sys,json; print(json.load(sys.stdin)['$FROM'])")
  aws route53 update-health-check --health-check-id "$PID" --inverted >/dev/null; t0=$SECONDS
  for i in $(seq 1 60); do
    r=$(answering); echo "  +$((SECONDS-t0))s answered by: $r"
    [ "$r" = "$TO" ] && { echo "  failed over from $FROM to $TO after about $((SECONDS-t0))s"; break; }; sleep 10
  done
  echo "  restoring the health check..."; revert_hc
  t1=$SECONDS; for i in $(seq 1 60); do r=$(answering); [ "$r" = "$FROM" ] && { echo "  back on $FROM after about $((SECONDS-t1))s"; break; }; sleep 10; done
fi
