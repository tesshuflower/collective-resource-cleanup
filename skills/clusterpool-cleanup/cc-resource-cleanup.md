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
2. Follow the steps in `skills/clusterpool-cleanup/_preflight-aws-readonly.md` to verify AWS read-only credentials. Store the profile as SCAN_PROFILE.
3. Check hiveutil: look for `~/DEV/openshift/hive/bin/hiveutil`
   - If not found: ask "Path to hiveutil binary?" — store as HIVEUTIL_PATH
   - If found: store path as HIVEUTIL_PATH
4. Check if hiveutil is up to date:
   - Run `git -C $(dirname $(dirname <HIVEUTIL_PATH>)) status` and check if behind origin
   - If behind: ask "hiveutil is out of date. Update before continuing? (y/n)"
     - If y: run `git -C $(dirname $(dirname <HIVEUTIL_PATH>)) pull && make -C $(dirname $(dirname <HIVEUTIL_PATH>)) build-hiveutil`

## Scan

Run: `KUBECONFIG=~/.kube/collective bash <REPO_ROOT>/scripts/scan-cc-resources.sh --profile <SCAN_PROFILE> --namespace <NAMESPACE>`

This outputs a JSON array of orphaned resource groups. Each entry has: `infra_id`, `region`, `resource_count`.

If the array is empty: say "No orphaned AWS resource groups found." — STOP

## Present cleanup plan

Show:

```
=== cc-resource-cleanup Plan ===

[HIGH CONFIDENCE — tagged resources with no active ClusterDeployment]
 [1] ✓  N orphaned resource groups across M regions

Commands: <number> to toggle group, e<number> to expand/collapse, <number><letter> to toggle individual item, Enter to proceed
```

When expanded, show each resource group:
- Infra ID
- Region
- Resource count

Handle toggle commands. When user presses Enter, proceed.

## AWS write credentials

Ask: "AWS profile for deletion (write access, e.g. aws-acm-dev11):"
Verify: `aws sts get-caller-identity --profile <WRITE_PROFILE>`
If it fails: "AWS write credentials invalid or expired." — STOP

## Confirm

"Proceed with selected deletions? (y/n)"
If n: STOP.

## Execute

For each selected resource group, immediately before acting:
- Re-query live ClusterDeployments: `KUBECONFIG=~/.kube/collective bash <REPO_ROOT>/scripts/scan-cc-resources.sh --profile <SCAN_PROFILE> --namespace <NAMESPACE>`
- If the infra_id now appears as live: skip, note as "Skipped (state changed)"

Run hiveutil for each confirmed orphan:
```
<HIVEUTIL_PATH> aws-tag-deprovision \
  kubernetes.io/cluster/<infra_id>=owned \
  --region <region> \
  --loglevel debug \
  --aws-creds-file ~/.aws/credentials \
  --profile <WRITE_PROFILE>
```

## Summary

```
cc-resource-cleanup summary:
  Resource groups cleaned:     N
  Skipped (state changed):     N
  Failed:                      N
```
