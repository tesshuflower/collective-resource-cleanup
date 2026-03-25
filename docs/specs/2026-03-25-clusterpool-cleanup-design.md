# Collective Resource Cleanup — Design Spec

**Date:** 2026-03-25
**Repo:** https://github.com/tesshuflower/collective-resource-cleanup

---

## Problem Statement

Clusters deployed via the collective cluster's ClusterPools on AWS are unreliable due to
provisioning failures. Investigation revealed two root causes:

1. **25+ ClusterDeployments stuck in `DeprovisionFailed`** (some 4+ years old) with expired
   AWS credentials — Hive cannot deprovision them, leaving orphaned AWS resources (VPCs,
   EC2 instances, security groups, EIPs, etc.) that consume shared account limits.

2. **Orphaned S3 buckets** not cleaned up when clusters are decommissioned:
   - Auto-generated OADP velero buckets (`managed-velero-backups-<uuid>`) from ROSA clusters
     used as ACM hubs with cluster-backup enabled
   - Manually pre-created velero buckets (e.g. `vb-velero-backup`) with no standardized tags

Additionally, ClusterDeployments stuck in `Provisioning` for extended periods are not
automatically cleaned up from the collective.

---

## Goals

- Investigate and clean up orphaned AWS resources and Kubernetes objects left behind by
  collective ClusterPool deployments
- Detect orphaned resources beyond what existing tools (`cleanaws.sh`, `ck-cluster-clean.sh`)
  handle, including resources from ROSA-based ACM hubs
- Require explicit user confirmation before any destructive action
- Provide rich context per flagged resource so the user understands exactly what it is and
  why it is flagged
- Support running individual cleanup steps independently or all together

---

## AWS Credentials

All skills use named AWS profiles. At startup, the skill prompts the user for which profile
to use.

- **Read-only profile** (`aws-acm-dev11-readonly`): used for all investigation/scanning steps.
  IAM policy: `tflower-cluster-investigation-readonly` (EC2, S3, Route53, IAM, resource
  tagging read actions).
- **Write profile** (`aws-acm-dev11`): used only for destructive actions, after explicit
  user confirmation.

Skills that require both will prompt for each profile separately.

---

## Skills

### `clusterpool-cleanup:cd-cleanup`

Cleans up stuck ClusterDeployment objects on the collective cluster.

**Permissions:**
- Collective cluster write (kubectl)
- No AWS credentials required

**Steps:**
1. Pre-flight: verify collective cluster access — attempt `kubectl get clusterpool -n app`.
   If it fails, prompt: `"Please log in: oc login <api-url>"` and exit.
2. Scan for:
   - ClusterDeployments in `DeprovisionFailed` state → flag for finalizer removal
   - ClusterDeployments stuck in `Provisioning` for >N hours → flag for deletion
3. Present expand/select/deselect interface (see UI section below).
4. Single confirm before performing any deletions.
5. Execute selected actions, with per-item safety re-check before acting.
6. Output summary.

**Summary:**
```
cd-cleanup summary:
  Finalizers removed:  N ClusterDeployments
  CDs deleted:         N (stuck Provisioning >Nh)
  Skipped:             N (active ClusterDeployment found at execution time)
  Failed:              N
```

---

### `clusterpool-cleanup:aws-resources`

Cleans up orphaned AWS resources left behind by collective ClusterDeployments, using
hiveutil's `aws-tag-deprovision`.

**Permissions:**
- AWS write credentials
- Collective cluster read (to cross-reference live ClusterDeployments)

**Steps:**
1. Pre-flight:
   - Prompt for AWS write profile, verify with `aws sts get-caller-identity`
   - Verify collective cluster access
   - Check hiveutil binary exists, prompt for path if not found at default
     (`~/DEV/openshift/hive/bin/hiveutil`)
2. Check hiveutil git status — if behind origin, prompt: `"hiveutil is out of date. Update
   before continuing? (y/n)"`. If yes: `git pull` + `make build-hiveutil`.
3. Scan AWS for `kubernetes.io/cluster/*` tagged resource groups with no corresponding
   live ClusterDeployment on the collective.
4. Present expand/select/deselect interface.
5. Single confirm before performing any deletions.
6. Run `hiveutil aws-tag-deprovision <tag>=owned --region <region>` for each confirmed item,
   with per-item safety re-check against live ClusterDeployments before acting.
7. Output summary.

**Summary:**
```
aws-resources summary:
  Resource groups cleaned:  N (via hiveutil)
  Skipped:                  N (active ClusterDeployment found at execution time)
  Failed:                   N
```

---

### `clusterpool-cleanup:investigate`

Scans the shared AWS account for ALL orphaned resources — including resources from outside
the collective/clusterpool scope (e.g. ROSA-based ACM hubs). Produces a human-readable
report and a structured `manifest.json` for use by `clusterpool-cleanup:execute`.

**Permissions:**
- AWS read-only credentials
- Collective cluster read

**Steps:**
1. Pre-flight:
   - Prompt for AWS read-only profile, verify with `aws sts get-caller-identity`
   - Verify collective cluster access
2. Warn if `aws-resources` cleanup has not been run (manifest from prior run absent):
   `"Collective ClusterPool Deployment Cleanup has not been run. Tagged AWS resources
   may still be present. Consider running clusterpool-cleanup:full instead."`
3. Scan for orphaned resources across all types (see Investigated Resource Types below).
4. Cross-reference each found resource against live ClusterDeployments on the collective.
5. Output human-readable report and write `manifest.json`.

**No confirmation required** — read-only, no destructive actions.

**Summary:**
```
investigate summary:
  Resources scanned:        N
  Orphaned (high conf):     N
  Orphaned (medium conf):   N
  Human review required:    N
  Manifest written to:      /tmp/clusterpool-cleanup-manifest.json
```

#### Investigated Resource Types

**AWS Resources (via `kubernetes.io/cluster/*` tags):**
- EC2 instances
- VPCs, subnets, route tables, internet gateways
- Security groups
- NAT gateways
- Elastic IPs
- Load balancers (ELB/NLB/ALB)
- IAM roles and instance profiles
- Route53 hosted zones
- S3 image registry buckets

**S3 Buckets — OADP auto-generated (`managed-velero-backups-<uuid>`):**
- Get `velero.io/infrastructureName` tag from each bucket
- If infra name is `rosa-*`: verify cluster is gone via AWS EC2 tags +
  Route53 hosted zone (both must be absent to flag as orphaned)
- If infra name matches a Hive pattern: cross-reference against collective
  ClusterDeployment infra IDs
- If orphaned: flag for deletion (HIGH or MEDIUM confidence depending on check results)

**S3 Buckets — manually pre-created (e.g. `vb-velero-backup`):**
- No standardized tags — cannot reliably link to a cluster
- Flag for HUMAN REVIEW only (deselected by default in execute UI)

**Collective ClusterDeployments:**
- `DeprovisionFailed` → flag for finalizer removal
- Stuck `Provisioning` >N hours → flag for deletion

#### Report Format Per Resource

Each flagged resource includes:
```
Resource:          managed-velero-backups-03c2d0d6-...
Type:              S3 bucket (OADP auto-generated velero backup)
Origin:            ROSA cluster rosa-yjcli-taeu-vtm4j — ACM hub with cluster-backup enabled
Created:           2026-02-14
Why orphaned:      No EC2 instances or Route53 hosted zone found for rosa-yjcli-taeu-vtm4j
                   — cluster has been removed from AWS
Confidence:        HIGH
Recommended action: Delete bucket
```

---

### `clusterpool-cleanup:execute`

Acts on a saved `manifest.json` from a prior `investigate` run.

**Permissions:**
- AWS write credentials
- Collective cluster write

**Steps:**
1. Pre-flight:
   - Prompt for AWS write profile, verify with `aws sts get-caller-identity`
   - Verify collective cluster access
   - Load `manifest.json` (prompt for path if not at default location)
2. Present expand/select/deselect interface grouped by confidence level.
3. Single confirm before performing any deletions.
4. Execute selected actions, with per-item safety re-check against live ClusterDeployments
   before acting. Skip and notify if a live CD is found.
5. Output summary.

**Summary:**
```
execute summary:
  Cleaned:   N items
  Skipped:   N items (active ClusterDeployment found at execution time)
  Failed:    N items
```

---

### `clusterpool-cleanup:full`

Convenience skill that runs all four steps in sequence.

**Order:**
1. `cd-cleanup`
2. `aws-resources`
3. `investigate`
4. `execute`

**Permissions:** All of the above. Prompts for read-only and write AWS profiles separately.

**Confirmation points (3 total):**
1. Before `cd-cleanup` performs any deletions
2. Before `aws-resources` performs any deletions
3. Before `execute` performs any deletions

**Summary:** Aggregates all four step summaries:
```
full summary:
  CD objects cleaned:          N
  AWS resource groups cleaned: N
  Remaining orphans found:     N
  Remaining orphans cleaned:   N
  Skipped (safety check):      N
  Failed:                      N
```

---

## UI — Expand/Select/Deselect Interface

Used by `cd-cleanup`, `aws-resources`, and `execute` before any destructive action.

```
=== Cleanup Plan ===

[HIGH CONFIDENCE]
 [1] ✓  14 OADP velero buckets from deleted ROSA clusters
 [2] ✓   3 image registry buckets (DeprovisionFailed CDs)
 [3] ✓   2 Collective ClusterPool Deployment Cleanup leftovers

[MEDIUM CONFIDENCE]
 [4] ✓   5 DeprovisionFailed ClusterDeployments (finalizer removal)
 [5] ✓   2 Provisioning CDs stuck >24h

[HUMAN REVIEW REQUIRED]
 [6] ✗   3 manually-named velero buckets (deselected by default)

Commands: <number> to toggle group, e<number> to expand/collapse,
          <1a 1b ...> to toggle individual items, Enter to proceed
> e1

  [1a] ✓  managed-velero-backups-03c2d0d6-...
           Origin: ROSA cluster rosa-yjcli-taeu-vtm4j — ACM hub, cluster-backup enabled
           Created: 2026-02-14
           Why orphaned: No EC2/Route53 found for infra ID rosa-yjcli-taeu-vtm4j
  [1b] ✓  managed-velero-backups-0c236023-...
           ...

> 1b      (deselect individual item)

  [1b] ✗  managed-velero-backups-0c236023-... (deselected)

> (Enter)

Proceed with selected items? (y/n)
> y
```

- Items in HUMAN REVIEW REQUIRED are deselected by default
- All other items are selected by default
- Groups can be toggled as a whole or expanded to toggle individual items
- Single confirm before performing any deletions

---

## Pre-flight Checks

All skills run these checks at startup before any other action:

1. **AWS profile** — prompt for profile name (suggest context-appropriate default),
   verify with `aws sts get-caller-identity`
2. **Collective cluster access** — attempt `kubectl get clusterpool -n app`.
   If it fails: `"Please log in first: oc login <api-url>"` then exit.
   No hardcoded usernames or context names.
3. **hiveutil binary** (`aws-resources` only) — check path, prompt if not found.

---

## Key Constraints

- No hardcoded usernames, context names, or account-specific values
- Read-only AWS profile used for all scanning; write profile only for destructive actions
- Every destructive action is preceded by a safety re-check against live ClusterDeployments
  on the collective — skip and report if a live CD is found
- `manifest.json` serves as an audit trail between investigate and execute runs
- Skills are independently invokable; `full` is a convenience wrapper
