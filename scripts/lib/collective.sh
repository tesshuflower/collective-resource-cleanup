#!/usr/bin/env bash
# Collective cluster query functions.

# Get infra IDs of all live (non-DeprovisionFailed) ClusterDeployments.
# Usage: get_live_infra_ids <namespace/clusterset>
# Prints one infra ID per line.
get_live_infra_ids() {
  local clusterset="$1"
  kubectl get clusterdeployment --all-namespaces \
    -l "cluster.open-cluster-management.io/clusterset=${clusterset}" \
    -o json 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
for cd in data.get('items', []):
    status = cd.get('status', {}).get('provisionStatus', '')
    if status != 'DeprovisionFailed':
        infra_id = cd.get('spec', {}).get('clusterMetadata', {}).get('infraID', '')
        if infra_id:
            print(infra_id)
"
}

# Get ClusterDeployments in DeprovisionFailed state as JSON array.
# Usage: get_deprovision_failed_cds <namespace/clusterset>
get_deprovision_failed_cds() {
  local clusterset="$1"
  kubectl get clusterdeployment --all-namespaces \
    -l "cluster.open-cluster-management.io/clusterset=${clusterset}" \
    -o json 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = []
for cd in data.get('items', []):
    if cd.get('status', {}).get('provisionStatus') == 'DeprovisionFailed':
        results.append({
            'name': cd.get('metadata', {}).get('name', ''),
            'namespace': cd.get('metadata', {}).get('namespace', ''),
            'infraID': cd.get('spec', {}).get('clusterMetadata', {}).get('infraID', ''),
        })
print(json.dumps(results))
"
}

# Get ClusterDeployments stuck in Provisioning for longer than threshold_hours.
# Usage: get_stuck_provisioning_cds <namespace/clusterset> <threshold_hours>
get_stuck_provisioning_cds() {
  local clusterset="$1"
  local threshold_hours="${2:-24}"
  kubectl get clusterdeployment --all-namespaces \
    -l "cluster.open-cluster-management.io/clusterset=${clusterset}" \
    -o json 2>/dev/null \
    | THRESHOLD_HOURS="$threshold_hours" python3 -c "
import sys, json, os
from datetime import datetime, timezone, timedelta
data = json.load(sys.stdin)
threshold = datetime.now(timezone.utc) - timedelta(hours=int(os.environ.get('THRESHOLD_HOURS', '24')))
results = []
for cd in data.get('items', []):
    if cd.get('status', {}).get('provisionStatus') == 'Provisioning':
        ts = cd.get('metadata', {}).get('creationTimestamp', '')
        try:
            created = datetime.fromisoformat(ts.replace('Z', '+00:00'))
            if created < threshold:
                results.append({
                    'name': cd.get('metadata', {}).get('name', ''),
                    'namespace': cd.get('metadata', {}).get('namespace', ''),
                    'createdAt': ts,
                })
        except ValueError:
            pass
print(json.dumps(results))
"
}

# Get current state of a single ClusterDeployment.
# Usage: get_cd_state <namespace> <name>
# Prints provisionStatus to stdout.
get_cd_state() {
  local namespace="$1"
  local name="$2"
  kubectl get clusterdeployment -n "$namespace" "$name" \
    -o jsonpath='{.status.provisionStatus}' 2>/dev/null
}
