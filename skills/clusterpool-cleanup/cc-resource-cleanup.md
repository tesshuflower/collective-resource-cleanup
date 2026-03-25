---
name: clusterpool-cleanup:cc-resource-cleanup
description: Clean up orphaned AWS resources left behind by collective ClusterPool deployments using hiveutil aws-tag-deprovision. Scans all regions for kubernetes.io/cluster/* tagged resources not claimed by any active ClusterDeployment.
---

# cc-resource-cleanup

Clean up orphaned AWS tagged resource groups from collective ClusterPool deployments.

## Pre-flight

Follow the steps in `skills/clusterpool-cleanup/_preflight.md` to set REPO_ROOT, KUBECONFIG, authenticate, and determine NAMESPACE.

Then: look for `~/DEV/openshift/hive/bin/hiveutil`
   - If not found: ask "Path to hiveutil binary?" — store as HIVEUTIL_PATH
   - If found: store path as HIVEUTIL_PATH
5. Check if hiveutil is up to date:
   - Run `git -C <hiveutil-repo-dir> status` and check if behind origin
   - If behind: ask "hiveutil is out of date. Update before continuing? (y/n)"
     - If y: run `git -C <hiveutil-repo-dir> pull && make -C <hiveutil-repo-dir> build-hiveutil`
6. Ask: "AWS profile to use for scanning (read-only, e.g. aws-acm-dev11-readonly):" — store as SCAN_PROFILE
7. Verify: `aws sts get-caller-identity --profile <SCAN_PROFILE>`
   - If it fails: "AWS credentials invalid or expired for profile <SCAN_PROFILE>. Please refresh and retry." — STOP

## Scan

Run: `bash <REPO_ROOT>/scripts/scan-cc-resources.sh --profile <SCAN_PROFILE> --namespace <NAMESPACE>`

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
- Re-query live ClusterDeployments: `bash <REPO_ROOT>/scripts/scan-cc-resources.sh --profile <SCAN_PROFILE> --namespace <NAMESPACE>`
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
