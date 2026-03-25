---
name: clusterpool-cleanup:full
description: Run all four collective cleanup steps in sequence: cd-cleanup, cc-resource-cleanup, investigate-orphans, then cleanup-orphans. Convenience wrapper that handles credential reuse across steps.
---

# full

Run all four collective cleanup steps in sequence.

**Order:**
1. `cd-cleanup` — clean up stuck ClusterDeployment objects
2. `cc-resource-cleanup` — clean up tagged AWS resource groups via hiveutil
3. `investigate-orphans` — scan broadly for remaining orphans, produce report
4. `cleanup-orphans` — act on the investigate-orphans report

## Shared state

Run the common pre-flight once at the start by following `skills/clusterpool-cleanup/_preflight.md`. This sets REPO_ROOT, KUBECONFIG, authenticates, and determines NAMESPACE. Do not re-run pre-flight for each step.

Also track these across steps:
- **WRITE_PROFILE** — asked in cc-resource-cleanup, reused for cleanup-orphans
- **READ_PROFILE** — asked in investigate-orphans, reused as safety re-check profile in cleanup-orphans

## Execution

### Step 1: cd-cleanup

Follow the `clusterpool-cleanup:cd-cleanup` skill, using the shared NAMESPACE.

**Confirmation point 1:** before any CD deletions.

### Step 2: cc-resource-cleanup

Follow the `clusterpool-cleanup:cc-resource-cleanup` skill, using the shared NAMESPACE and REPO_ROOT.

AWS write profile (WRITE_PROFILE) is prompted here and stored for reuse.

**Confirmation point 2:** before any AWS resource deletions.

### Step 3: investigate-orphans

Follow the `clusterpool-cleanup:investigate-orphans` skill, using the shared NAMESPACE and REPO_ROOT.

AWS read-only profile (READ_PROFILE) is prompted here and stored for reuse.

After this step, the manifest is at `/tmp/clusterpool-cleanup-manifest.json` with `cc_resource_cleanup_run: true`.

Update the manifest to mark `cc_resource_cleanup_run` as true (since cc-resource-cleanup just ran):
```bash
source <REPO_ROOT>/scripts/lib/manifest.sh
manifest_set_cc_resource_cleanup_run /tmp/clusterpool-cleanup-manifest.json true
```

### Step 4: cleanup-orphans

Follow the `clusterpool-cleanup:cleanup-orphans` skill, using:
- Shared NAMESPACE, REPO_ROOT
- WRITE_PROFILE (already obtained — skip the write profile prompt)
- READ_PROFILE (already obtained — use as the safety re-check profile)
- Manifest path: `/tmp/clusterpool-cleanup-manifest.json` (skip path prompt)

**Confirmation point 3:** before any deletions.

## Aggregate summary

After all steps complete, print:

```
=== full summary ===
  CD objects cleaned:          N  (finalizers removed + deletions)
  AWS resource groups cleaned: N  (via hiveutil)
  Remaining orphans found:     N  (from investigate-orphans)
  Remaining orphans cleaned:   N  (from cleanup-orphans)
  Skipped (state changed):     N
  Failed:                      N
```
