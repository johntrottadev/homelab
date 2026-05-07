#!/usr/bin/env bash
# tools/flux-envsubst-check.sh
# Sources:
#   https://fluxcd.io/flux/cmd/flux_envsubst/
#   .planning/phases/03-parameterize-site-values/03-RESEARCH.md §Pitfall 2
#
# Reproducible CFG-05 drift check + CFG-02 calibrated audit gate.
# Diffs the substituted Flux render against the pre-parameterization baseline
# captured in Plan 03-01, then runs the literal-detection audit grep with
# trailing-inline-comment stripping.
#
# Usage:
#   ./tools/flux-envsubst-check.sh
#   BASELINE=path/to/other.yaml ./tools/flux-envsubst-check.sh
#   CLUSTER_VARS_FILE=path/to/cluster-vars.yaml ./tools/flux-envsubst-check.sh
#
# Exit codes:
#   0 = drift clean AND audit clean (both gates pass)
#   1 = drift detected (see /tmp/drift.diff for unified diff)
#   2 = tooling missing or input file missing (re-run after fixing)
#   3 = audit residuals detected (see /tmp/03-05-audit-non-d10.txt and
#       /tmp/03-05-audit-ips-non-d10.txt; both must be empty for CFG-02 PASS)
set -euo pipefail

BASELINE="${BASELINE:-.planning/phases/03-parameterize-site-values/baselines/baseline.yaml}"
CLUSTER_VARS_FILE="${CLUSTER_VARS_FILE:-/Volumes/code/secrets/homelab/cluster-vars.yaml}"

# Allowed-literal IP set per D-10 (per-VM IPs that legitimately stay literal).
# Pipe-separated regex for grep -vE.
ALLOWED_IPS='10\.10\.1\.3|10\.10\.1\.4|10\.10\.1\.14|10\.10\.2\.10|10\.10\.2\.11|10\.10\.2\.12|10\.10\.3\.19|10\.10\.3\.38|10\.10\.3\.39|10\.10\.3\.40|10\.10\.3\.42|10\.10\.3\.45|10\.10\.3\.46|10\.10\.3\.47|10\.10\.3\.69|10\.10\.3\.70'

# --- Gate 1: tooling sanity ---
flux version --client 2>/dev/null | grep -q v2 || { echo "tools/flux-envsubst-check.sh: flux v2.x missing (install via brew install fluxcd/tap/flux)"; exit 2; }
kustomize version >/dev/null 2>&1 || { echo "tools/flux-envsubst-check.sh: kustomize missing (install via brew install kustomize)"; exit 2; }
command -v yq >/dev/null 2>&1 || { echo "tools/flux-envsubst-check.sh: yq missing (install via brew install yq)"; exit 2; }
command -v awk >/dev/null 2>&1 || { echo "tools/flux-envsubst-check.sh: awk missing (should never happen on a *nix system)"; exit 2; }

# --- Gate 0: CWD sanity ---
[[ -d clusters/default ]] || {
  echo "tools/flux-envsubst-check.sh: must be run from the repo root (clusters/default not found)"
  exit 2
}

# --- Gate 2: input files ---
test -s "$BASELINE" || { echo "tools/flux-envsubst-check.sh: baseline file missing or empty: $BASELINE"; exit 2; }
test -s "$CLUSTER_VARS_FILE" || { echo "tools/flux-envsubst-check.sh: cluster-vars file missing or empty: $CLUSTER_VARS_FILE"; exit 2; }

# --- CFG-05 drift gate ---
# Extract data: keys from cluster-vars ConfigMap into env vars for flux envsubst.
# Note: assumes data: contains string-leaf values (no maps/lists).
# Safe export: yq emits key=value lines; read assigns without shell interpretation.
while IFS='=' read -r key value; do
  export "$key=$value"
done < <(yq '.data | to_entries[] | .key + "=" + .value' "$CLUSTER_VARS_FILE")

kustomize build clusters/default/ \
  | flux envsubst --strict \
  > /tmp/substituted.yaml

diff -u "$BASELINE" /tmp/substituted.yaml > /tmp/drift.diff || true

if [[ -s /tmp/drift.diff ]]; then
  echo "DRIFT DETECTED — see /tmp/drift.diff"
  echo "First 50 lines of diff:"
  head -50 /tmp/drift.diff
  exit 1
fi

echo "DRIFT CLEAN — substituted render is byte-equivalent to baseline"

# --- CFG-02 audit gate (BLOCKER-2 fix from revision iteration 3) ---
#
# Recipe approach: grep produces "file:lineno:content" rows. We use awk to:
#   1. Strip leading whitespace from content; if first non-space char is `#`,
#      drop the row (full-line comment).
#   2. Strip trailing inline comments matching `[[:space:]]+#.*` from content.
#   3. Re-test the residual content against the literal-detection regex; only
#      print rows whose residual STILL contains a literal.
# This handles both YAML and HCL comment styles (`# comment`).
#
# Bucket A: __BASE-DOMAIN__ + __WASABI-BUCKET__ residuals (any non-comment value-position
# occurrence is a parameterization bug; no allowed-literal carve-out exists
# for these patterns).
grep -rnE 'jt-lab\.net|__WASABI-BUCKET__' \
  --include='*.yaml' --include='*.yml' --include='*.tf' \
  --exclude='*.example' --exclude='*.example.yaml' --exclude='*.tfvars.example' \
  clusters/default/ terraform/ docker-1/ docker-2/ 2>/dev/null \
  | awk -F: '{
      file=$1; lineno=$2;
      rest=substr($0, length($1)+length($2)+3);
      gsub(/^[[:space:]]+/, "", rest);
      if (substr(rest,1,1) == "#") next;
      sub(/[[:space:]]+#.*$/, "", rest);
      if (rest ~ /jt-lab\.net|__WASABI-BUCKET__/) print file ":" lineno ":" rest;
    }' \
  > /tmp/03-05-audit-non-d10.txt || true

# Bucket B: 10.10.x.x IP literals; same comment stripping, then exclude the
# per-D-10 allowed-IP set.
grep -rnE '10\.10\.[0-9]+\.[0-9]+' \
  --include='*.yaml' --include='*.yml' --include='*.tf' \
  --exclude='*.example' --exclude='*.example.yaml' --exclude='*.tfvars.example' \
  clusters/default/ terraform/ docker-1/ docker-2/ 2>/dev/null \
  | awk -F: '{
      file=$1; lineno=$2;
      rest=substr($0, length($1)+length($2)+3);
      gsub(/^[[:space:]]+/, "", rest);
      if (substr(rest,1,1) == "#") next;
      sub(/[[:space:]]+#.*$/, "", rest);
      if (rest ~ /10\.10\.[0-9]+\.[0-9]+/) print file ":" lineno ":" rest;
    }' \
  | grep -vE "${ALLOWED_IPS}" \
  > /tmp/03-05-audit-ips-non-d10.txt || true

NON_D10=$(wc -l < /tmp/03-05-audit-non-d10.txt | tr -d ' ')
IPS_NON_D10=$(wc -l < /tmp/03-05-audit-ips-non-d10.txt | tr -d ' ')

echo "audit-non-d10 lines: $NON_D10"
echo "audit-ips-non-d10 lines: $IPS_NON_D10"

if [[ "$NON_D10" != "0" || "$IPS_NON_D10" != "0" ]]; then
  echo "AUDIT RESIDUALS DETECTED — fix the source manifests and re-run."
  echo "  /tmp/03-05-audit-non-d10.txt:"
  head -20 /tmp/03-05-audit-non-d10.txt
  echo "  /tmp/03-05-audit-ips-non-d10.txt:"
  head -20 /tmp/03-05-audit-ips-non-d10.txt
  exit 3
fi

echo "AUDIT CLEAN — both audit-non-d10 and audit-ips-non-d10 are empty"
echo "ALL CFG-02 + CFG-05 GATES PASS"
exit 0
