#!/usr/bin/env bash
# Scan AWS for tagged resource groups from collective ClusterDeployments with no live CD.
# Outputs JSON array of orphaned resource groups with region, infra_id, resource_count, resources.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/aws.sh"
source "${SCRIPT_DIR}/lib/collective.sh"

PROFILE=""
NAMESPACE="app"
REGION_FILTER=""
NAME_FILTER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --region-filter) REGION_FILTER="$2"; shift 2 ;;
    --name-filter) NAME_FILTER="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$PROFILE" ]] && { echo "ERROR: --profile required" >&2; exit 1; }

# Get live infra IDs from collective — check all namespaces to protect all active clusters
live_infra_ids=$(get_live_infra_ids)
if [[ -z "$live_infra_ids" ]]; then
  echo "ERROR: no live ClusterDeployments found on collective. If active clusters exist, check your kubectl connection. Refusing to continue — treating all AWS resources as orphaned would be destructive." >&2
  exit 1
fi

regions=$(get_aws_regions "$PROFILE") || { echo "ERROR: failed to list AWS regions — check credentials for profile '$PROFILE'" >&2; exit 1; }
if [[ -z "$regions" ]]; then
  echo "ERROR: no AWS regions returned for profile '$PROFILE'" >&2
  exit 1
fi

TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
echo "[]" > "$TMPFILE"

while IFS= read -r region; do
  # Apply region filter if specified
  if [[ -n "$REGION_FILTER" ]] && [[ "$region" != *"$REGION_FILTER"* ]]; then
    continue
  fi
  while IFS= read -r infra_id; do
    [[ -z "$infra_id" ]] && continue
    # Apply name filter if specified
    if [[ -n "$NAME_FILTER" ]] && [[ "$infra_id" != *"$NAME_FILTER"* ]]; then
      continue
    fi
    # Skip if this infra ID belongs to a live CD
    if infra_id_is_live "$live_infra_ids" "$infra_id"; then
      continue
    fi
    # Get resources for this infra ID
    resources=$(get_infra_resources "$PROFILE" "$region" "$infra_id" 2>/dev/null) || continue
    [[ -z "$resources" ]] && continue
    RESOURCES_JSON="$resources" python3 - "$TMPFILE" "$infra_id" "$region" <<'PYEOF'
import json, sys, os

def resource_type(arn):
    parts = arn.split(':')
    if len(parts) >= 6:
        resource = parts[5]
        return resource.split('/')[0] if '/' in resource else resource
    return 'unknown'

arns = json.loads(os.environ['RESOURCES_JSON'])
path, infra_id, region = sys.argv[1], sys.argv[2], sys.argv[3]
if not arns:
    sys.exit(0)
types = {}
for arn in arns:
    rt = resource_type(arn)
    types[rt] = types.get(rt, 0) + 1
with open(path) as f:
    items = json.load(f)
items.append({"infra_id": infra_id, "region": region, "resource_count": len(arns), "resource_types": types})
with open(path, "w") as f:
    json.dump(items, f, indent=2)
PYEOF
  done < <(get_cluster_tag_keys "$PROFILE" "$region")
done <<< "$regions"

cat "$TMPFILE"
