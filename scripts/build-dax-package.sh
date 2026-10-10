#!/usr/bin/env bash
# Builds the read Lambda's package WITH the DAX client, for use when enable_dax is true.
#
# The default package (src/get-order) has no dependencies: it uses the SDK built into the Lambda runtime. The DAX client
# is not in that runtime, so it is installed here from the committed lockfile into build/get-order-dax (git-ignored), which
# Terraform zips instead of src/get-order when enable_dax is true. Run this before `terraform apply -var enable_dax=true`.
#
# Safe by design: `npm ci` installs exactly what package-lock.json pins (with integrity hashes), and install scripts are
# disabled (--ignore-scripts), so installing cannot run package code.
# Needs Node and npm; on WSL without Node it falls back to the Windows installation.
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
SRC="$ROOT/src/get-order"
OUT="$ROOT/build/get-order-dax"

rm -rf "$OUT"
mkdir -p "$OUT"
cp "$SRC/index.mjs" "$SRC/get-order.mjs" "$SRC/client.mjs" "$SRC/package.json" "$SRC/package-lock.json" "$OUT/"

if command -v npm >/dev/null 2>&1; then
  (cd "$OUT" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund)
elif [ -x "/mnt/c/Program Files/nodejs/npm.cmd" ] && command -v powershell.exe >/dev/null 2>&1; then
  echo "npm not found in WSL; building with the Windows installation of Node."
  TMP="/mnt/c/Users/Public/build-dax-$$"
  trap 'rm -rf "$TMP"' EXIT
  mkdir -p "$TMP"
  cp "$OUT/package.json" "$OUT/package-lock.json" "$TMP/"
  WINDIR_TMP=$(wslpath -w "$TMP")
  powershell.exe -NoProfile -Command "Set-Location '$WINDIR_TMP'; & 'C:\\Program Files\\nodejs\\npm.cmd' ci --omit=dev --ignore-scripts --no-audit --no-fund" | tr -d '\r'
  cp -r "$TMP/node_modules" "$OUT/node_modules"
else
  echo "Node and npm are required (install Node.js 22 or newer), then re-run this script." >&2
  exit 1
fi

[ -f "$OUT/node_modules/@amazon-dax-sdk/lib-dax/package.json" ] || { echo "DAX client was not installed" >&2; exit 1; }

# Drop what Node never loads at runtime (TypeScript declarations, ES-module builds and source maps). The AWS SDK packages
# load from dist-cjs, so this roughly halves the package without changing behaviour.
find "$OUT/node_modules" -type d \( -name dist-es -o -name dist-types \) -prune -exec rm -rf {} +
find "$OUT/node_modules" -type f \( -name '*.d.ts' -o -name '*.map' \) -delete

echo
echo "Built $OUT"
echo "  files: $(find "$OUT" -type f | wc -l), size: $(python3 -c "import os,sys;print(round(sum(os.path.getsize(os.path.join(r,f)) for r,_,fs in os.walk(sys.argv[1]) for f in fs)/1e6,1))" "$OUT") MB unzipped"
echo "  DAX client: $(python3 -c "import json;print(json.load(open('$OUT/node_modules/@amazon-dax-sdk/lib-dax/package.json'))['version'])")"
echo "Next: terraform apply -var enable_dax=true   (billing starts), and when finished: terraform apply   (removes it)."
