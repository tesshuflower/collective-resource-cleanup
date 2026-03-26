---
name: clusterpool-cleanup:cc-resource-cleanup
description: Clean up orphaned AWS resources left behind by collective ClusterPool deployments using hiveutil aws-tag-deprovision. Scans all regions for kubernetes.io/cluster/* tagged resources not claimed by any active ClusterDeployment.
---

# cc-resource-cleanup

## Overview

Before starting, tell the user:

> **cc-resource-cleanup** will:
> 1. Connect to the collective cluster and verify AWS read-only credentials
> 2. Scan all AWS regions for `kubernetes.io/cluster/*` tagged resource groups not claimed by any active ClusterDeployment
> 3. Show a plan for review
> 4. Prompt for AWS write credentials and confirm before making any changes
> 5. Run `hiveutil aws-tag-deprovision` for each confirmed orphan
> 6. Print a summary of what was done

## Pre-flight

1. Follow the steps in `skills/clusterpool-cleanup/_preflight.md` to set REPO_ROOT, KUBECONFIG, authenticate, and determine NAMESPACE.
2. Follow the steps in `skills/clusterpool-cleanup/_preflight-aws-readonly.md` to verify AWS read-only credentials. Store the profile as AWS_READ_PROFILE.
3. Find hiveutil:
   - Check config: read `~/.config/collective-resource-cleanup/config.json` if it exists.
     - If `hiveutil_path` is set and the file exists: use it as HIVEUTIL_PATH. Tell the user: "Using saved hiveutil: <HIVEUTIL_PATH>"
     - If not set: run `which hiveutil 2>/dev/null`
       - If found: store as HIVEUTIL_PATH
       - If not found: ask "Path to hiveutil binary?" — store as HIVEUTIL_PATH
     - Offer to save: "Save this hiveutil path to config? (y/n)"
       - If y: write `hiveutil_path` to `~/.config/collective-resource-cleanup/config.json` (create file and directory if needed, preserve any existing keys).
4. Check if hiveutil is up to date:
   - Run `git -C $(dirname $(dirname <HIVEUTIL_PATH>)) status` and check if behind origin
   - If behind: ask "hiveutil is out of date. Update before continuing? (y/n)"
     - If y: run `git -C $(dirname $(dirname <HIVEUTIL_PATH>)) pull && make -C $(dirname $(dirname <HIVEUTIL_PATH>)) build-hiveutil`

## Scan

Ask the user for optional filters before scanning:

```
Region filter:
  1) No filter (scan all regions)
  2) Enter a region substring (e.g. "us-east")
```
Wait for selection. If 2, ask "Region substring:" and wait for input. Store as REGION_FILTER (empty if 1).

```
Name filter:
  1) No filter (match all infra IDs)
  2) Enter a name substring (e.g. "app-prow")
```
Wait for selection. If 2, ask "Name substring:" and wait for input. Store as NAME_FILTER (empty if 1).

Build the scan command:
```
KUBECONFIG=~/.kube/collective bash <REPO_ROOT>/scripts/scan-cc-resources.sh \
  --profile <AWS_READ_PROFILE> \
  --namespace <NAMESPACE> \
  [--region-filter <REGION_FILTER>] \
  [--name-filter <NAME_FILTER>]
```
(omit flags whose values are empty)

This outputs a JSON array of orphaned resource groups. Each entry has: `infra_id`, `region`, `resource_count`.

If the array is empty: say "No orphaned AWS resource groups found." — STOP

## Present cleanup plan

Split results into two groups based on resource count:
- **Small (≤10 resources)**: likely leftover tag stubs from a deprovisioned cluster. Selected for deletion by default.
- **Large (>10 resources)**: likely an active or manually-created cluster not tracked by the collective. Deselected by default and hidden — user must explicitly expand to review.

Show:

```
=== cc-resource-cleanup Plan ===

[HIGH CONFIDENCE — tagged resources with no active ClusterDeployment]
 [1] ✓  N resource groups (≤10 resources each) across M regions

[LIKELY ACTIVE — large resource counts, no ClusterDeployment found]
 [2] ✗  N resource groups (>10 resources each)  (deselected — expand to review)

Commands: <number> to toggle group, e<number> to expand/collapse, <number><letter> to toggle individual item, "go" to proceed
```

- Group 1 (small) is selected by default.
- Group 2 (large) is deselected and collapsed by default. When the user expands it (e2), show each item with infra ID, region, and resource count, and warn: "⚠ These have large resource counts and may be active clusters not registered with the collective. Verify before selecting."

When expanded, show each resource group:
- Infra ID
- Region
- Resource count

Handle toggle commands. When user types "go", proceed.

## AWS write credentials

Follow the steps in `skills/clusterpool-cleanup/_preflight-aws-write.md` to verify AWS write credentials. Store the profile as AWS_WRITE_PROFILE.

## Confirm

List the selected resource groups and tell the user they will be cleaned up using `hiveutil aws-tag-deprovision`. Then ask: "Proceed? (y/n)"
If n: STOP.

## Execute

### Setup

Ask the user:
```
Max parallel deletions:
  1) 5 (default)
  2) Enter a different number
```
Wait for selection. If 2, ask "Max parallel:" and wait for input. Store as MAX_PARALLEL.

Create a log directory and tell the user its location:
```bash
LOGDIR=$(mktemp -d /tmp/cc-resource-cleanup-$(date +%Y%m%d)-XXXXXX)
```
"Logs for this run: <LOGDIR>"

### Parallel execution

Run hiveutil for confirmed orphans in batches of up to MAX_PARALLEL. Before each batch, re-fetch live infra IDs:
```bash
KUBECONFIG=~/.kube/collective bash -c 'set -o pipefail; source <REPO_ROOT>/scripts/lib/collective.sh && get_live_infra_ids'
```
If this command fails or returns empty output: STOP — do not proceed. Tell the user: "ERROR: Could not re-fetch live ClusterDeployments from collective. Aborting to avoid deleting active cluster resources."

Use `infra_id_is_live <live_ids> <infra_id>` to skip any item now claimed by a live CD — note as "Skipped (state changed)".

For each confirmed orphan in the batch, log stdout+stderr to `<LOGDIR>/<infra_id>-<region>.log` and run in the background:

```bash
AWS_PROFILE=<AWS_WRITE_PROFILE> <HIVEUTIL_PATH> aws-tag-deprovision \
  kubernetes.io/cluster/<infra_id>=owned \
  --region <region> \
  --loglevel debug \
  > <LOGDIR>/<infra_id>-<region>.log 2>&1 &
```

Start up to MAX_PARALLEL jobs simultaneously. Wait for all jobs in the batch to finish before starting the next batch. After each batch completes, report which items finished and whether they succeeded (exit code 0) or failed, e.g.:
```
  ✓ app-prow-small-aws-42-6nk95 (us-east-1)
  ✗ app-prow-small-aws-42-74rpb (us-east-1) — see <LOGDIR>/app-prow-small-aws-42-74rpb-us-east-1.log
```

After all batches: "Full logs available in <LOGDIR>"

## Summary

```
cc-resource-cleanup summary:
  Resource groups cleaned:     N
  Skipped (state changed):     N
  Failed:                      N
  Logs:                        <LOGDIR>
```
