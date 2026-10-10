#!/usr/bin/env bash
# Cold-start and memory benchmark for the save-order Lambda.
#
# Creates a TEMPORARY copy of the production function (same role, runtime, architecture and
# tracing), then for every variant x memory size forces cold starts, makes warm requests, and
# prints a Markdown table of medians. Every request is a real DynamoDB write, so the numbers
# include the full path. The scratch function and all benchmark rows are deleted on exit, even
# if the run fails or is interrupted. Production is never modified.
#
# Needs: AWS credentials (aws sso login), python3, openssl, a deployed save-order function.
# Cost: well inside the free tiers (a few hundred invocations, a few thousand GB-ms).
# Account concurrency must allow 5 parallel invocations (new accounts default to 10).
#
# Environment overrides (defaults in brackets):
#   MEMORIES  space-separated MB sizes ["128 256 512"]
#   VARIANTS  names under scripts/benchmark/variants, plus "baseline" ["baseline slim-imports init-warmup"]
#   BATCHES   batches of 5 parallel cold starts per configuration [2]
#   WARM      warm requests per configuration [5]
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
PROD=${PROD_FUNCTION:-save-order}
TABLE=${TABLE_NAME:-Orders}
MEMORIES=${MEMORIES:-"128 256 512"}
VARIANTS=${VARIANTS:-"baseline slim-imports init-warmup"}
BATCHES=${BATCHES:-2}
WARM=${WARM:-5}

RUN=$(openssl rand -hex 3)
FN="${PROD}-bench-${RUN}"
PREFIX="bench-${RUN}-"
WORK=$(mktemp -d)
: >"$WORK/results.tsv"

cleanup() {
  echo >&2; echo "Cleaning up..." >&2
  aws lambda delete-function --function-name "$FN" >/dev/null 2>&1 || true
  python3 - "$TABLE" "$PREFIX" <<'PY' >&2 || true
import json, subprocess, sys
table, prefix = sys.argv[1:3]
def aws(*a): return subprocess.run(["aws", *a], capture_output=True, text=True, check=True).stdout
keys = json.loads(aws("dynamodb", "scan", "--table-name", table, "--filter-expression", "begins_with(orderId, :p)",
    "--expression-attribute-values", json.dumps({":p": {"S": prefix}}), "--projection-expression", "orderId,itemId",
    "--query", "Items", "--output", "json") or "[]")
for i in range(0, len(keys), 25):
    chunk = [{"DeleteRequest": {"Key": k}} for k in keys[i:i + 25]]
    aws("dynamodb", "batch-write-item", "--request-items", json.dumps({table: chunk}))
print(f"  deleted {len(keys)} benchmark rows")
PY
  echo "  scratch function deleted: $FN" >&2
  rm -rf "$WORK"
}
trap cleanup EXIT

# Copy the production function's settings so the benchmark is representative.
read -r ROLE RUNTIME ARCH TRACING < <(aws lambda get-function-configuration --function-name "$PROD" \
  --query '[Role,Runtime,Architectures[0],TracingConfig.Mode]' --output text)

build_zip() { # $1=variant
  python3 - "$ROOT" "$1" "$WORK/$1.zip" <<'PY'
import os, sys, zipfile
root, variant, out = sys.argv[1:4]
src = f"{root}/src/save-order"
vdir = f"{root}/scripts/benchmark/variants"
files = {"save-order.mjs": f"{src}/save-order.mjs"}
if variant == "baseline":
    files["index.mjs"] = f"{src}/index.mjs"
else:
    files["index.mjs"] = f"{vdir}/{variant}/index.mjs"
    files["marshal.mjs"] = f"{vdir}/marshal.mjs"
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for name, path in sorted(files.items()):
        z.write(path, name)
print(os.path.getsize(out))
PY
}

invoke() { # $1=orderId  $2=output file for the REPORT line
  aws lambda invoke --function-name "$FN" --cli-binary-format raw-in-base64-out --log-type Tail \
    --payload "{\"orderId\":\"$1\",\"itemId\":\"i-1\",\"quantity\":1,\"price\":1.5}" /dev/null \
    --query LogResult --output text 2>/dev/null | base64 -d 2>/dev/null | grep '^REPORT' >"$2" || true
}

record() { # $1=variant $2=memory $3=report file
  python3 - "$@" >>"$WORK/results.tsv" <<'PY'
import re, sys
variant, mem, path = sys.argv[1:4]
text = open(path).read()
def grab(p): m = re.search(p, text); return m.group(1) if m else ""
print("\t".join([variant, mem, grab(r"Duration: ([\d.]+) ms"), grab(r"Billed Duration: (\d+) ms"),
                 grab(r"Max Memory Used: (\d+) MB"), grab(r"Init Duration: ([\d.]+) ms")]))
PY
}

wait_updated() { aws lambda wait function-updated-v2 --function-name "$FN"; }

echo "Benchmarking $PROD settings: $RUNTIME, $ARCH, tracing $TRACING (scratch function: $FN)" >&2
FIRST=1
for mem in $MEMORIES; do
  for variant in $VARIANTS; do
    zip_bytes=$(build_zip "$variant")
    echo "  $variant @ ${mem} MB (package $zip_bytes bytes)" >&2
    if [ "$FIRST" = 1 ]; then
      aws lambda create-function --function-name "$FN" --runtime "$RUNTIME" --architectures "$ARCH" \
        --handler index.handler --role "$ROLE" --timeout 10 --memory-size "$mem" \
        --environment "Variables={TABLE_NAME=$TABLE,BENCH=$RANDOM}" --tracing-config "Mode=$TRACING" \
        --zip-file "fileb://$WORK/$variant.zip" >/dev/null
      aws lambda wait function-active-v2 --function-name "$FN"
      FIRST=0
    else
      aws lambda update-function-configuration --function-name "$FN" --memory-size "$mem" \
        --environment "Variables={TABLE_NAME=$TABLE,BENCH=$RANDOM}" >/dev/null && wait_updated
      aws lambda update-function-code --function-name "$FN" --zip-file "fileb://$WORK/$variant.zip" >/dev/null && wait_updated
    fi
    for batch in $(seq 1 "$BATCHES"); do
      [ "$batch" -gt 1 ] && { aws lambda update-function-configuration --function-name "$FN" \
        --environment "Variables={TABLE_NAME=$TABLE,BENCH=$RANDOM}" >/dev/null && wait_updated; }  # new environments
      for i in 1 2 3 4 5; do invoke "${PREFIX}${variant}-${mem}-c${batch}-${i}" "$WORK/c$i.txt" & done
      wait
      for i in 1 2 3 4 5; do record "$variant" "$mem" "$WORK/c$i.txt"; done
      if [ "$batch" = 1 ]; then
        for i in $(seq 1 "$WARM"); do invoke "${PREFIX}${variant}-${mem}-w${i}" "$WORK/w.txt"; record "$variant" "$mem" "$WORK/w.txt"; done
      fi
    done
  done
done

# A sample is "cold" if its report has an Init Duration. A late request in a parallel burst can land on an
# already-initialised environment, so samples are classified by that field, not by which batch they came from.
python3 - "$WORK/results.tsv" "$VARIANTS" "$MEMORIES" <<'PY'
import collections, csv, statistics as st, sys
path, variants, memories = sys.argv[1], sys.argv[2].split(), sys.argv[3].split()
cold, warm = collections.defaultdict(list), collections.defaultdict(list)
for variant, mem, dur, billed, mx, init in csv.reader(open(path), delimiter="\t"):
    if not dur:
        continue
    row = (float(dur), float(billed), int(mx), float(init) if init else None)
    (cold if init else warm)[(variant, int(mem))].append(row)
p90 = lambda xs: sorted(xs)[max(0, int(round(0.9 * len(xs))) - 1)]
print("| Variant | Memory | Cold samples | Init (ms) | First request (ms) | **Cold total (ms)** | Cold p90 (ms) | Warm (ms) | Max memory (MB) |")
print("|---|---|---|---|---|---|---|---|---|")
for mem in memories:
    for variant in variants:
        c, w = cold[(variant, int(mem))], warm[(variant, int(mem))]
        if not c:
            continue
        tot = [e[3] + e[0] for e in c]
        print(f"| {variant} | {mem} MB | {len(c)} | {st.median(e[3] for e in c):.0f} | {st.median(e[0] for e in c):.0f} | "
              f"**{st.median(tot):.0f}** | {p90(tot):.0f} | {st.median(e[0] for e in w):.0f} | {max(e[2] for e in c + w)} |"
              if w else
              f"| {variant} | {mem} MB | {len(c)} | {st.median(e[3] for e in c):.0f} | {st.median(e[0] for e in c):.0f} | "
              f"**{st.median(tot):.0f}** | {p90(tot):.0f} | n/a | {max(e[2] for e in c)} |")
PY
