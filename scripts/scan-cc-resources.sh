#!/usr/bin/env bash
# Scan AWS for tagged resource groups from collective ClusterDeployments with no live CD.
# Outputs JSON array of orphaned resource groups with region, infra_id, resource_count, resources.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/aws.sh"
source "${SCRIPT_DIR}/lib/collective.sh"

PROFILE=""
NAMESPACE="app"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$PROFILE" ]] && { echo "ERROR: --profile required" >&2; exit 1; }

# Get live infra IDs from collective
live_infra_ids=$(get_live_infra_ids "$NAMESPACE")
if [[ -z "$live_infra_ids" ]]; then
  echo "WARNING: no live infra IDs returned from collective (kubectl may be unavailable). All tagged resources will appear as orphaned." >&2
fi

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
echo "[]" > "$TMPFILE"

while IFS= read -r region; do
  while IFS= read -r infra_id; do
    [[ -z "$infra_id" ]] && continue
    # Skip if this infra ID belongs to a live CD
    if echo "$live_infra_ids" | grep -qxF "$infra_id"; then
      continue
    fi
    # Get resources for this infra ID
    resources=$(get_infra_resources "$PROFILE" "$region" "$infra_id" 2>/dev/null) || continue
    [[ -z "$resources" ]] && continue
    count=$(echo "$resources" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))") || continue
    if [[ "${count:-0}" -gt 0 ]]; then
      python3 - "$TMPFILE" "$infra_id" "$region" "$count" <<'PYEOF'
import json, sys
path, infra_id, region, count = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
with open(path) as f:
    items = json.load(f)
items.append({"infra_id": infra_id, "region": region, "resource_count": count})
with open(path, "w") as f:
    json.dump(items, f, indent=2)
PYEOF
    fi
  done < <(get_cluster_tag_keys "$PROFILE" "$region")
done < <(get_aws_regions "$PROFILE")

cat "$TMPFILE"
