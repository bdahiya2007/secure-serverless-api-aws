#!/usr/bin/env bash
# WAF rate-limit check (run with enable_waf=true): sends N unauthenticated GETs from this machine and prints "time n status".
# Expect 401 (reached API Gateway) and then 403 (blocked by WAF) after the limit; enforcement lags, so more than the limit
# gets through first. The IP stays blocked for about 5 minutes afterwards, for valid requests too. No credentials or data are
# created. Usage: scripts/demo/waf-checks.sh [N=300]
set -uo pipefail
cd "$(git rev-parse --show-toplevel)/terraform/environments/dev"
BASE=$(terraform output -raw create_order_url); BASE=${BASE%/orders}
N=${1:-300}; first_block=0
for i in $(seq 1 "$N"); do
  c=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/orders/waf-test-$i")
  echo "$(date -u +%T) $i $c"
  if [ "$c" = 403 ] && [ $first_block = 0 ]; then first_block=$i; echo "first 403 at request $i" >&2; fi
done
