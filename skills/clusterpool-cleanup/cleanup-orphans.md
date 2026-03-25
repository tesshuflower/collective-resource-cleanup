---
name: clusterpool-cleanup:cleanup-orphans
description: Act on findings from a prior investigate-orphans run. Reads the manifest, presents an interactive selection UI grouped by confidence, then executes selected deletions with per-item safety re-checks.
---

# cleanup-orphans

## Overview

Before starting, tell the user:

> **cleanup-orphans** will:
> 1. Connect to the collective cluster
> 2. Load the manifest from a prior `investigate-orphans` run
> 3. Show findings grouped by confidence level for review and selection
> 4. Prompt for AWS write credentials and confirm before making any changes
> 5. Delete selected resources with per-item safety re-checks
> 6. Print a summary of what was done

## Pre-flight

1. Follow the steps in `skills/clusterpool-cleanup/_preflight.md` to set REPO_ROOT, KUBECONFIG, authenticate, and determine NAMESPACE.
2. Load manifest:
   - Check if `/tmp/clusterpool-cleanup-manifest.json` exists
   - If not: ask "Path to manifest file?"
   - Read and parse the manifest

If `cc_resource_cleanup_run` is false in the manifest: warn "cc-resource-cleanup has not been run this session. Tagged AWS resources may still be present. Consider running clusterpool-cleanup:full instead." Continue.

## Present cleanup plan

Group findings from the manifest by confidence level:

```
=== cleanup-orphans Plan ===

[HIGH CONFIDENCE]
 [1] ✓  N items
     [examples of what they are]

[MEDIUM CONFIDENCE]
 [2] ✓  N items

[HUMAN REVIEW REQUIRED — no automated safety check]
 [3] ✗  N items  (deselected by default)

Commands: <number> to toggle group, e<number> to expand/collapse, <number><letter> to toggle item, Enter to proceed
```

- HIGH and MEDIUM items are selected by default
- HUMAN REVIEW items are deselected by default
- When a HUMAN REVIEW group is selected: warn "⚠ These items have no automated safety check. Expand (e<N>) to review before proceeding."

When expanded, show each item:
- Resource name
- Type
- Why flagged as orphaned
- Recommended action

Handle toggle commands. When user presses Enter, proceed.

## AWS credentials

Ask: "AWS profile for deletion (write access, e.g. aws-acm-dev11):" — store as WRITE_PROFILE
Ask: "AWS read-only profile (for safety re-checks, e.g. aws-acm-dev11-readonly):" — store as READ_PROFILE
Verify write profile: `aws sts get-caller-identity --profile <WRITE_PROFILE>`
If it fails: "AWS write credentials invalid or expired." — STOP

## Confirm

If any HUMAN REVIEW items are selected: "⚠ <N> selected items have no automated safety check (no cluster linkage)."

"Proceed with selected items? (y/n)"
If n: STOP.

## Execute

For each selected item:

### Standard items (HIGH / MEDIUM confidence)

Perform a safety re-check immediately before acting:
- **S3 buckets with velero infra tag**: re-check that the infra ID still has no active EC2 resources
- **IAM roles/profiles**: re-check that no running EC2 instances use the role
- **AWS tagged resource groups**: re-check via `scripts/scan-cc-resources.sh --profile <READ_PROFILE> --namespace <NAMESPACE>` that the infra ID is still not claimed by a live CD
- **Route53 zones**: re-check that no active cluster uses the zone

If re-check finds the resource is now in use: skip and report as "Skipped (state changed at execution time)"

**Deletion commands by type:**

S3 bucket (OADP velero):
```
aws s3 rb s3://<bucket-name> --force --profile <WRITE_PROFILE>
```

IAM role:
```
aws iam delete-role --role-name <name> --profile <WRITE_PROFILE>
```
(detach policies first if needed)

IAM instance profile:
```
aws iam delete-instance-profile --instance-profile-name <name> --profile <WRITE_PROFILE>
```

Route53 hosted zone: note the zone ID then delete all records and the zone itself.

AWS tagged resource group: use hiveutil if available, otherwise flag as requiring manual cleanup.

### HUMAN REVIEW items

No automated safety check. Delete directly:
```
aws s3 rb s3://<bucket-name> --force --profile <WRITE_PROFILE>
```
(or appropriate deletion command for the resource type)

## Summary

```
cleanup-orphans summary:
  Cleaned:                     N items
  Skipped (state changed):     N items
  Failed:                      N items
```

## Update knowledge base

After completing cleanup, append a run summary to `<REPO_ROOT>/knowledge/run-history/<date>-run.md`.

Note which items were confirmed orphaned (user approved deletion) vs skipped. Update `knowledge/orphan-patterns.md` if user decisions revealed new patterns.
