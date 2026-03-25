---
name: clusterpool-cleanup:cd-cleanup
description: Clean up stuck ClusterDeployment objects on the collective cluster (DeprovisionFailed and stuck Provisioning). Requires collective cluster write access via kubectl. No AWS credentials needed.
---

# cd-cleanup

Clean up stuck ClusterDeployment objects on the collective cluster.

## Pre-flight

Follow the steps in `skills/clusterpool-cleanup/_preflight.md` to set REPO_ROOT, KUBECONFIG, authenticate, and determine NAMESPACE.

## Scan

Run: `bash <REPO_ROOT>/scripts/scan-cds.sh --namespace <NAMESPACE>`

Parse the JSON output:
- `deprovision_failed[]` — CDs needing finalizer removal
- `stuck_provisioning[]` — CDs needing deletion

If both lists are empty: say "Nothing to clean up." — STOP

## Present cleanup plan

Show the following interface (fill in actual counts):

```
=== cd-cleanup Plan ===

[MEDIUM CONFIDENCE]
 [1] ✓  N DeprovisionFailed ClusterDeployments (finalizer removal)
 [2] ✓  N Provisioning CDs stuck >24h (deletion)

Commands: <number> to toggle group, e<number> to expand/collapse, <number><letter> to toggle individual item, Enter to proceed
```

When expanded (e.g. after user types `e1`), show each CD:
- Name and namespace
- Current state and reason
- Age

Handle toggle commands. When user presses Enter, proceed to confirm.

## Confirm

"Proceed with selected items? (y/n)"
If n: STOP.

## Execute

For each selected item, immediately before acting:
- Re-query: `kubectl get clusterdeployment -n <namespace> <name> -o jsonpath='{.status.provisionStatus}'`
- If state has changed from what was scanned: skip, note as "Skipped (state changed)"

**For DeprovisionFailed CDs** (finalizer removal):
```
kubectl patch clusterdeployment -n <namespace> <name> \
  -p '{"metadata":{"finalizers":[]}}' --type=merge
```

**For stuck Provisioning CDs** (deletion):
```
kubectl delete clusterdeployment -n <namespace> <name>
```

## Summary

Print:
```
cd-cleanup summary:
  Finalizers removed:      N
  CDs deleted:             N
  Skipped (state changed): N
  Failed:                  N
```
