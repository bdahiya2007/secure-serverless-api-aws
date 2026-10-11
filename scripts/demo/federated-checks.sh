#!/usr/bin/env bash
# Checks for sign-in with Google (enable_federated_signin). First sign in with the helper, once per region you test:
#   scripts/demo/google-signin.py                       # the primary region's pool
#   scripts/demo/google-signin.py --region us-west-2    # the second region's pool (only with enable_multi_region)
# Then run this script. It reads the saved ID tokens (never prints them) and checks that:
#   1 requests without a token, or with a garbage token, get 401 on every API
#   2 a token from each pool is accepted by every API (a 404 for a missing order means "accepted"; 401 means "refused")
#   3 a write made with a Google token reads back, and (with multi-region) replicates and reads back in the other region
# Creates only order rows with a "fed-" prefix and removes them on exit. The Google users themselves stay in their pools
# (they are real sign-ins); remove one with: aws cognito-idp admin-delete-user --user-pool-id <pool> --username <name>.
# Needs: AWS credentials, terraform, curl, openssl, python3.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)/terraform/environments/dev"
CACHE=~/.cache/orders-api
P_REGION=${AWS_REGION:-us-east-1}
P_BASE=$(terraform output -raw create_order_url); P_BASE=${P_BASE%/orders}
D_URL=$(terraform output -json dr_create_order_url | tr -d '"'); D_BASE=""; [ "$D_URL" != "null" ] && D_BASE=${D_URL%/orders}
D_REGION=$(terraform output -json federated_signin | python3 -c "import sys,json; c=json.load(sys.stdin) or {}; print(next((r for r in c if r!='$P_REGION'),''))")
PFX="fed-$(openssl rand -hex 3)"
cleanup() {
  python3 - "$PFX" <<'PY'
import json,subprocess,sys
p=sys.argv[1]; aws=lambda *a: subprocess.run(["aws",*a],capture_output=True,text=True,check=True).stdout
k=json.loads(aws("dynamodb","scan","--table-name","Orders","--filter-expression","begins_with(orderId, :p)","--expression-attribute-values",json.dumps({":p":{"S":p}}),"--projection-expression","orderId,itemId","--query","Items","--output","json") or "[]")
for i in range(0,len(k),25): aws("dynamodb","batch-write-item","--request-items",json.dumps({"Orders":[{"DeleteRequest":{"Key":x}} for x in k[i:i+25]]}))
print(f"cleanup: deleted {len(k)} order rows")
PY
}
trap cleanup EXIT
tok() { cat "$CACHE/id_token-$1" 2>/dev/null; }
code() { curl -s -o /dev/null -w '%{http_code}' -m 20 "$@"; }
verdict() { case "$1" in 200|404) echo "accepted";; 401|403) echo "REFUSED";; *) echo "unexpected";; esac; }

T_P=$(tok "$P_REGION"); [ -z "$T_P" ] && { echo "No saved token for $P_REGION: run scripts/demo/google-signin.py first."; exit 1; }
T_D=""; [ -n "$D_REGION" ] && T_D=$(tok "$D_REGION")
APIS=("$P_REGION|$P_BASE"); [ -n "$D_BASE" ] && APIS+=("${D_REGION:-second}|$D_BASE")

echo "== 1 no token / garbage token"
for a in "${APIS[@]}"; do r=${a%%|*}; b=${a#*|}
  echo "$r API: no token $(code "$b/orders-via-lambda/x") | garbage token $(code -H 'Authorization: not.a.token' "$b/orders-via-lambda/x")   (expect 401 and 401)"; done

echo; echo "== 2 each pool's Google token on each API"
for src in "$P_REGION|$T_P" "${D_REGION:-none}|$T_D"; do sr=${src%%|*}; st=${src#*|}; [ -z "$st" ] && continue
  for a in "${APIS[@]}"; do r=${a%%|*}; b=${a#*|}; c=$(code -H "Authorization: $st" "$b/orders-via-lambda/x")
    echo "token from the $sr pool on the $r API: HTTP $c ($(verdict "$c"))"; done; done

echo; echo "== 3 write with a Google token, read back (and across regions)"
echo "POST via $P_REGION: HTTP $(code -X POST "$P_BASE/orders" -H "Content-Type: application/json" -H "Authorization: $T_P" -d "{\"orderId\":\"$PFX-A\",\"itemId\":\"i-1\",\"quantity\":3}")"
echo "read back via $P_REGION: HTTP $(code -H "Authorization: $T_P" "$P_BASE/orders-via-lambda/$PFX-A")"
if [ -n "$D_BASE" ]; then
  for i in $(seq 1 30); do c=$(code -H "Authorization: $T_P" "$D_BASE/orders-via-lambda/$PFX-A"); [ "$c" = 200 ] && break; sleep 0.5; done
  echo "read via the second region with the primary-pool token: HTTP $c (after about $i polls)"
  [ -n "$T_D" ] && echo "read via the second region with the second-pool token: HTTP $(code -H "Authorization: $T_D" "$D_BASE/orders-via-lambda/$PFX-A")"
fi
