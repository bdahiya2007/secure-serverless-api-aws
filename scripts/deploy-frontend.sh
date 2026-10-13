#!/usr/bin/env bash
# Publishes src/frontend/ to the front end's private bucket and refreshes CloudFront.
#   scripts/deploy-frontend.sh [--dry-run]
# What it does: uploads the page's files (never the tests, the package file or config.json, which Terraform manages), with cache
# headers (HTML revalidates every time; scripts and styles are cached for 5 minutes), removes files that no longer exist in
# src/frontend, then invalidates the CloudFront cache so the change is visible within a minute.
# Needs: terraform/frontend applied, AWS credentials, aws CLI, terraform. Cost: pennies at most (the first 1,000 invalidation paths
# a month are free). After it, run scripts/demo/frontend-checks.sh.
set -euo pipefail
TOP=$(git rev-parse --show-toplevel)
DRY=""; [ "${1:-}" = "--dry-run" ] && DRY="--dryrun"
BUCKET=$(terraform -chdir="$TOP/terraform/frontend" output -raw bucket_name)
DIST=$(terraform -chdir="$TOP/terraform/frontend" output -raw distribution_id)
SRC="$TOP/src/frontend"
EXCLUDES=(--exclude "*.test.mjs" --exclude "package.json" --exclude "README.md" --exclude "config.json")

echo "== node unit tests first (a broken page is not published)"
node --test "$SRC/"*.test.mjs >/dev/null || { echo "The front end's unit tests fail: not publishing." >&2; exit 1; }

echo "== upload (HTML: no-cache; scripts and styles: 5 minutes)"
aws s3 sync "$SRC/" "s3://$BUCKET/" $DRY --delete "${EXCLUDES[@]}" --exclude "*" --include "*.html" --cache-control "no-cache" --content-type "text/html; charset=utf-8"
aws s3 sync "$SRC/" "s3://$BUCKET/" $DRY --delete "${EXCLUDES[@]}" --exclude "*" --include "*.js" --cache-control "public, max-age=300" --content-type "text/javascript; charset=utf-8"
aws s3 sync "$SRC/" "s3://$BUCKET/" $DRY --delete "${EXCLUDES[@]}" --exclude "*" --include "*.css" --cache-control "public, max-age=300" --content-type "text/css; charset=utf-8"

if [ -n "$DRY" ]; then echo "(dry run: nothing was changed)"; exit 0; fi
echo "== refresh CloudFront"
aws cloudfront create-invalidation --distribution-id "$DIST" --paths "/*" --query 'Invalidation.Status' --output text
echo "published. Check it with scripts/demo/frontend-checks.sh"
