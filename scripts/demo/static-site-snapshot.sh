#!/usr/bin/env bash
# Proves that adding the front end changed NOTHING about an existing CloudFront-and-S3 website in the same account and zone.
#   scripts/demo/static-site-snapshot.sh save       BEFORE the front end is applied: records read-only fingerprints
#   scripts/demo/static-site-snapshot.sh compare    AFTER: reports every fingerprint as unchanged or CHANGED
# It finds the existing site by its own name (the Route 53 zone name as a CloudFront alias), so no IDs are written down anywhere.
# Fingerprints: the distribution's configuration, its web ACL, the S3 origin bucket's policy, and every DNS record in the zone
# (after the apply there may be NEW records, but every old one must be identical). Everything is read-only. The snapshot is a local file
# (~/.cache/orders-api/static-site-snapshot.json) with hashes only; nothing is committed.
# Needs: AWS credentials, aws CLI, python3, curl. ZONE=<zone name> overrides the zone read from terraform/frontend/terraform.tfvars.
set -euo pipefail
MODE=${1:-}; [ "$MODE" = save ] || [ "$MODE" = compare ] || { echo "usage: $0 save|compare" >&2; exit 2; }
TOP=$(git rev-parse --show-toplevel)
ZONE=${ZONE:-$(sed -n 's/^route53_zone_name *= *"\(.*\)".*/\1/p' "$TOP/terraform/frontend/terraform.tfvars" 2>/dev/null | head -1)}
[ -n "$ZONE" ] || { echo "Set ZONE=<your zone name> (or terraform/frontend/terraform.tfvars)." >&2; exit 2; }
FILE=~/.cache/orders-api/static-site-snapshot.json; mkdir -p ~/.cache/orders-api

python3 - "$MODE" "$ZONE" "$FILE" <<'PY'
import hashlib, json, subprocess, sys
mode, zone, path = sys.argv[1:4]
aws = lambda *a: json.loads(subprocess.run(["aws", *a, "--output", "json"], capture_output=True, text=True, check=True).stdout or "null")
h = lambda o: hashlib.sha256(json.dumps(o, sort_keys=True, default=str).encode()).hexdigest()[:16]

def fingerprint():
    out = {}
    dists = aws("cloudfront", "list-distributions", "--query", "DistributionList.Items[]") or []
    mine = [d for d in dists if zone in (d.get("Aliases", {}).get("Items") or [])]
    if not mine:
        sys.exit(f"No CloudFront distribution with the alias {zone} found: nothing to protect, or the wrong zone name.")
    d = mine[0]
    cfg = aws("cloudfront", "get-distribution-config", "--id", d["Id"])
    out["distribution config"] = h(cfg["DistributionConfig"]) + f" (version {cfg['ETag']})"
    out["distribution aliases"] = ",".join(sorted(d["Aliases"]["Items"]))
    acl = cfg["DistributionConfig"].get("WebACLId")
    if acl:
        parts = acl.split("/")                      # arn:...:global/webacl/<name>/<id>
        got = aws("wafv2", "get-web-acl", "--scope", "CLOUDFRONT", "--region", "us-east-1", "--name", parts[-2], "--id", parts[-1])
        out["web ACL (rules and lock token)"] = h(got["WebACL"]["Rules"]) + " lock " + got["LockToken"][:8]
    for o in cfg["DistributionConfig"]["Origins"]["Items"]:
        dom = o["DomainName"]
        if dom.endswith(".s3.us-east-1.amazonaws.com") or ".s3." in dom:
            bucket = dom.split(".s3.")[0]
            try:
                pol = aws("s3api", "get-bucket-policy", "--bucket", bucket, "--query", "Policy")
                out[f"S3 origin bucket policy #{o['Id']}"] = h(pol)
            except subprocess.CalledProcessError:
                out[f"S3 origin bucket policy #{o['Id']}"] = "none"
    zid = aws("route53", "list-hosted-zones-by-name", "--dns-name", zone, "--query", "HostedZones[0].Id").split("/")[-1]
    recs = aws("route53", "list-resource-record-sets", "--hosted-zone-id", zid, "--query", "ResourceRecordSets")
    out["_records"] = {f"{r['Name']} {r['Type']} {r.get('SetIdentifier','')}": h(r) for r in recs}
    return out

now = fingerprint()
if mode == "save":
    json.dump(now, open(path, "w"), indent=1)
    recs = now.pop("_records")
    print(f"saved a snapshot of the existing site for {zone}:")
    for k, v in now.items(): print(f"  {k}: {v}")
    print(f"  DNS records in the zone: {len(recs)}")
    sys.exit(0)

before = json.load(open(path))
changed = 0
brec, nrec = before.pop("_records"), now.pop("_records")
for k, v in before.items():
    ok = now.get(k) == v
    changed += not ok
    print(f"  {'unchanged' if ok else 'CHANGED  '}  {k}" + ("" if ok else f"\n      before: {v}\n      after:  {now.get(k)}"))
for k, v in brec.items():
    ok = nrec.get(k) == v
    changed += not ok
    if not ok: print(f"  CHANGED    DNS record {k}")
new = sorted(set(nrec) - set(brec))
print(f"  unchanged  all {len(brec)} existing DNS records are identical" if not any(nrec.get(k) != v for k, v in brec.items()) else "  (see CHANGED records above)")
print(f"  new DNS records added: {len(new)}")
for k in new: print(f"      + {k}")
print("\nresult:", "NOTHING about the existing site changed." if changed == 0 else f"{changed} difference(s): look before going on.")
sys.exit(1 if changed else 0)
PY
