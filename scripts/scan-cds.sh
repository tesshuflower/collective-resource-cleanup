#!/usr/bin/env bash
# Scan collective cluster for stuck ClusterDeployments.
# Outputs JSON: {deprovision_failed: [...], stuck_provisioning: [...]}

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/collective.sh"

NAMESPACE="app"
STUCK_THRESHOLD_HOURS=24

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --threshold-hours) STUCK_THRESHOLD_HOURS="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

deprovision_failed=$(get_deprovision_failed_cds "$NAMESPACE")
stuck_provisioning=$(get_stuck_provisioning_cds "$NAMESPACE" "$STUCK_THRESHOLD_HOURS")

python3 - "$deprovision_failed" "$stuck_provisioning" <<'PYEOF'
import json, sys
deprovision_failed = json.loads(sys.argv[1])
stuck_provisioning = json.loads(sys.argv[2])
print(json.dumps({
    'deprovision_failed': deprovision_failed,
    'stuck_provisioning': stuck_provisioning
}, indent=2))
PYEOF
