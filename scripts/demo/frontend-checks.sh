#!/usr/bin/env bash
# Checks the deployed front end (terraform/frontend applied): HTTPS and TLS, redirects, the security headers, a private bucket,
# the public config file, and the 404 behaviour. Read-only; about 15 requests; creates nothing.
#   scripts/demo/frontend-checks.sh                    (reads the name from terraform/frontend/terraform.tfvars)
#   SITE=orders.example.com scripts/demo/frontend-checks.sh
# Needs: curl with TLS 1.3 support, python3, terraform, AWS credentials. Run it a few minutes after an apply (a new CloudFront
# distribution and certificate take a little while to reach every edge location).
set -uo pipefail
TOP=$(git rev-parse --show-toplevel)
SITE=${SITE:-$(sed -n 's/^domain_name *= *"\(.*\)".*/\1/p' "$TOP/terraform/frontend/terraform.tfvars" 2>/dev/null | head -1)}
[ -n "$SITE" ] || { echo "Set SITE=<front end name> (or terraform/frontend/terraform.tfvars)." >&2; exit 2; }
BUCKET=$(terraform -chdir="$TOP/terraform/frontend" output -raw bucket_name 2>/dev/null || true)
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  ok   $1"; }
skip() { SKIP=$((SKIP+1)); echo "  skip $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# Until the page (index.html) and its error page (error.html) are uploaded, CloudFront has nothing to serve or to swap in for a missing
# file, so it passes S3's plain 403 through; those checks are skipped, not failed. Everything else (TLS, headers, config.json) is checked.
HAS_PAGE=0
if [ -n "$BUCKET" ] && aws s3api head-object --bucket "$BUCKET" --key index.html >/dev/null 2>&1 && aws s3api head-object --bucket "$BUCKET" --key error.html >/dev/null 2>&1; then HAS_PAGE=1; fi
H=$(curl -sI -m 20 "https://$SITE/" | tr -d '\r'); STATUS=$(echo "$H" | head -1 | awk '{print $2}')
hv() { echo "$H" | awk -F': ' -v n="$1" 'tolower($1)==tolower(n){sub(/^[^:]*: /,""); print; exit}'; }

echo "== $SITE: HTTPS, TLS and redirects"
if [ $HAS_PAGE = 1 ]; then check "the page is served (200)" '[ "$STATUS" = 200 ]'; else skip "the page is served (200): index.html and error.html are not uploaded yet"; fi
check "CloudFront answers over HTTPS (any status)"            '[ -n "$STATUS" ]'
check "plain HTTP redirects to HTTPS"                           '[ "$(curl -s -o /dev/null -m 20 -w "%{http_code} %{redirect_url}" "http://$SITE/")" = "301 https://$SITE/" ]'
check "TLS 1.3 works"                                           'curl -s -o /dev/null -m 20 --tlsv1.3 "https://$SITE/"'
check "TLS 1.2 is refused (minimum TLS 1.3)"                    '! curl -s -o /dev/null -m 20 --tls-max 1.2 "https://$SITE/"'
check "the certificate is for this exact name"                  'echo | openssl s_client -connect "$SITE:443" -servername "$SITE" 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName 2>/dev/null | grep -q "$SITE"'
check "HTTP/3 is advertised (alt-svc)"                          'echo "$H" | grep -qi "^alt-svc:.*h3"'

echo "== security headers"
check "Strict-Transport-Security, 2 years, subdomains"          '[[ "$(hv strict-transport-security)" == *max-age=63072000* && "$(hv strict-transport-security)" == *includeSubDomains* ]]'
check "X-Content-Type-Options: nosniff"                          '[ "$(hv x-content-type-options)" = nosniff ]'
check "X-Frame-Options: DENY"                                    '[ "$(hv x-frame-options)" = DENY ]'
check "Referrer-Policy: strict-origin-when-cross-origin"         '[ "$(hv referrer-policy)" = strict-origin-when-cross-origin ]'
check "Cross-Origin-Opener-Policy and Resource-Policy: same-origin" '[ "$(hv cross-origin-opener-policy)" = same-origin ] && [ "$(hv cross-origin-resource-policy)" = same-origin ]'
check "Permissions-Policy denies camera, microphone, geolocation" '[[ "$(hv permissions-policy)" == *camera=\(\)* && "$(hv permissions-policy)" == *microphone=\(\)* && "$(hv permissions-policy)" == *geolocation=\(\)* ]]'
CSP=$(hv content-security-policy)
check "CSP: default-src none, scripts and styles only from self"  '[[ "$CSP" == *"default-src '"'"'none'"'"'"* && "$CSP" == *"script-src '"'"'self'"'"'"* && "$CSP" == *"style-src '"'"'self'"'"'"* ]]'
check "CSP: frame-ancestors none and no unsafe-inline/eval"       '[[ "$CSP" == *"frame-ancestors '"'"'none'"'"'"* && "$CSP" != *unsafe-inline* && "$CSP" != *unsafe-eval* ]]'
check "CSP: connect-src allows only self, the API and the sign-in host" 'echo "$CSP" | tr ";" "\n" | grep -q "connect-src '"'"'self'"'"' https://[a-z0-9.-]*execute-api" && echo "$CSP" | tr ";" "\n" | grep "connect-src" | grep -q "amazoncognito.com" && ! echo "$CSP" | grep -q "connect-src[^;]*\*"'

echo "== the bucket is private and the config is public and secret-free"
if [ -n "$BUCKET" ]; then
  check "the bucket URL itself is not readable (403)"           '[ "$(curl -s -o /dev/null -m 20 -w "%{http_code}" "https://$BUCKET.s3.amazonaws.com/config.json")" = 403 ]'
fi
CFG=$(curl -s -m 20 "https://$SITE/config.json")
check "config.json is JSON with the API URL, sign-in host, client ID and redirect URI" 'echo "$CFG" | python3 -c "import sys,json; c=json.load(sys.stdin); assert c[\"apiBaseUrl\"].startswith(\"https://\") and c[\"cognito\"][\"host\"] and c[\"cognito\"][\"clientId\"] and c[\"redirectUri\"]==\"https://$SITE/\""'
check "config.json holds no secret-looking keys"                 '! echo "$CFG" | grep -qiE "secret|password|token|private"'
check "config.json is not cached (no-cache)"                     'curl -sI -m 20 "https://$SITE/config.json" | grep -qi "^cache-control:.*no-cache"'

echo "== missing files"
if [ $HAS_PAGE = 1 ]; then
  check "a missing file returns a real 404"                      '[ "$(curl -s -o /dev/null -m 20 -w "%{http_code}" "https://$SITE/does-not-exist-$RANDOM.html")" = 404 ]'
  check "a request for a private-looking path returns 404"       '[ "$(curl -s -o /dev/null -m 20 -w "%{http_code}" "https://$SITE/.git/config")" = 404 ]'
else
  skip "a missing file returns a real 404: needs error.html uploaded"
  skip "a private-looking path returns 404: needs error.html uploaded"
  check "a missing file is never served (not 200)"               '[ "$(curl -s -o /dev/null -m 20 -w "%{http_code}" "https://$SITE/.git/config")" != 200 ]'
fi
echo; echo "result: $PASS passed, $FAIL failed, $SKIP skipped"; [ "$FAIL" = 0 ]
