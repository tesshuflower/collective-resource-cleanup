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

This outputs a JSON array of orphaned resource groups. Each entry has: `infra_id`, `region`, `resource_count`, `resource_types` (map of resource type to count, e.g. `{"subnet": 8, "vpc": 1}`), and `iam_create_date` (ISO8601 timestamp from the infra ID's IAM master instance profile, or `null` if not found).

If the array is empty: say "No orphaned AWS resource groups found." — STOP

## Load knowledge base

Read `<REPO_ROOT>/knowledge/resource-classification-rules.md` — this defines the shared rules for
classifying resource groups as HIGH confidence vs HUMAN REVIEW. Apply these rules when presenting
the cleanup plan below.

## Present cleanup plan

Group scan results by `infra_id` — a single cluster may have resources in multiple regions (e.g.
IAM instance profiles appear in us-east-1 regardless of where the cluster ran). Each infra_id is
one logical entry; regions are sub-items.

Classify each infra_id using the rules from `knowledge/resource-classification-rules.md` (Steps 1–3,
applied across the combined resource count and `iam_create_date` across all regions for that infra_id):
- **SKIP (possibly in-flight)**: `iam_create_date` ≤ 24h ago — do not show in plan at all.
- **HIGH confidence**: no active CD, IAM age confirmed old (or profile not found), and either ≤10
  total resources OR >10 with no running EC2. Selected by default.
- **HUMAN REVIEW**: no active CD, >10 total resources, and has running EC2. Deselected by default and hidden.

Show:

```
=== cc-resource-cleanup Plan ===

[HIGH CONFIDENCE — tagged resources with no active ClusterDeployment]
 [1] ✓  N clusters (across M regions)

[HUMAN REVIEW — large resource counts with running EC2, no ClusterDeployment found]
 [2] ✗  N clusters  (deselected — expand to review)

Commands: <number> to toggle group, e<number> to expand/collapse, <number><letter> to toggle individual item, "go" to proceed
```

- Group 1 is selected by default.
- Group 2 is deselected and collapsed by default. When the user expands it (e2), warn: "⚠ These have running EC2 instances and may be active clusters not registered with the collective. Verify before selecting."

When a group is expanded, show each cluster as a lettered entry with its regions indented below:

```
   a  ✓  app-prow-small-aws-42-4h47s
             us-east-1   2 resources  (instance-profile ×2)
             us-west-2  10 resources  (subnet ×8, vpc ×1, internet-gateway ×1)
   b  ✓  app-prow-small-aws-42-6nk95
             us-east-1   2 resources  (instance-profile ×2)
```

Format resource types as `type ×N`, omitting `×1`. Sort types by count descending.

If a region filter was applied, add a note at the top of the expanded group:
```
   ⚠ Region filter active (us-) — resources in other regions are not shown and will not be cleaned.
     A cluster may have additional orphaned resources outside the scanned regions.
```

Toggle commands operate at the cluster (infra_id) level:
- `<number>` toggles the whole group
- `e<number>` expands/collapses a group
- `<number><letter>` toggles an individual cluster

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
