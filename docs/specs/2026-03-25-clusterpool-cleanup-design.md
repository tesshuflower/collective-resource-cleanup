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
  IAM policy: `tflower-cluster-investigation-readonly`.
  Required IAM actions: `ec2:Describe*`, `s3:ListAllMyBuckets`, `s3:ListBucket`,
  `s3:GetBucketTagging`, `s3:GetBucketLocation`, `route53:List*`, `route53:Get*`,
  `iam:List*`, `iam:Get*`, `resourcegroupstaggingapi:GetResources`,
  `resourcegroupstaggingapi:GetTagKeys`, `sts:GetCallerIdentity`,
  `elasticloadbalancing:Describe*`.
- **Write profile** (`aws-acm-dev11`): used only for destructive actions, after explicit
  user confirmation.

AWS credentials are prompted at the point they are first needed — not upfront.

---

## Manifest

The `investigate-orphans` skill writes its findings to:

```
/tmp/clusterpool-cleanup-manifest.json
```

The `cleanup-orphans` skill reads from this path by default, skipping the path prompt when
invoked via `clusterpool-cleanup:full`. When invoked standalone, `cleanup-orphans` prompts
for the path if the default does not exist.

The manifest includes a field `"cc_resource_cleanup_run": true/false` indicating whether
`cc-resource-cleanup` was run in the same session. This is used by `investigate-orphans` to
warn the user — not manifest file presence.

---

## AWS Tag Scanning

All resource group scans use the AWS Resource Groups Tagging API:

```
aws resourcegroupstaggingapi get-tag-keys --region <region>
aws resourcegroupstaggingapi get-resources --region <region> \
  --tag-filters Key=kubernetes.io/cluster/<infraID>,Values=owned
```

Regions are enumerated via `aws ec2 describe-regions`. S3 bucket listing and IAM are
global and handled separately from the regional scan loop.

---

## Safety Re-check Definition

Each skill performs a per-item re-check immediately before executing a destructive action:

- **`cd-cleanup`**: Re-query the ClusterDeployment from the collective API and verify it
  still has the same state (e.g., `DeprovisionFailed`) before removing the finalizer.
  If state has changed, skip and report.
- **`aws-resources`**: Re-query the collective for live ClusterDeployments and verify the
  infra ID is still not claimed by any active CD before running hiveutil.
- **`execute`**: Re-query both the collective (live CDs) and the AWS tagging API to verify
  the resource is still present and unclaimed before deleting.
  Exception: HUMAN REVIEW items selected by the user have no automated safety check —
  the user is warned explicitly before the final confirm (see UI section).

If a re-check finds the resource is now in use or state has changed, the item is skipped
and reported in the summary as "Skipped (state changed at execution time)".

---

## Stuck Provisioning Threshold

ClusterDeployments stuck in `Provisioning` are flagged if they have been in that state
for more than **24 hours**. This default is used by both `cd-cleanup` and `investigate`
and is not currently user-configurable.

---

## Region Handling

- **Regional resources** (EC2, VPCs, security groups, NAT gateways, EIPs, load balancers,
  Route53 hosted zones): scanned across all regions returned by `aws ec2 describe-regions`.
- **Global resources** (IAM roles, instance profiles): queried once without a region.
- **S3**: bucket listing is global (`aws s3 ls`); per-bucket operations use the bucket's
  own region obtained via `aws s3api get-bucket-location`.

---

## Skills

### `clusterpool-cleanup:cd-cleanup`

Cleans up stuck ClusterDeployment objects on the collective cluster.

**Permissions:**
- Collective cluster write (kubectl)
- No AWS credentials required

**Steps:**
1. Pre-flight: verify collective cluster access — attempt `kubectl get clusterpool -n app`.
   If it fails, prompt: `"Please log in first: oc login <api-url>"` and exit.
2. Scan for:
   - ClusterDeployments in `DeprovisionFailed` state → flag for finalizer removal
   - ClusterDeployments stuck in `Provisioning` for >24h → flag for deletion
3. Present expand/select/deselect interface (see UI section below).
4. Single confirm before performing any deletions.
5. Execute selected actions. Per-item safety re-check immediately before each action
   (re-query CD state from collective API; skip if state has changed).
6. Output summary.

**Summary:**
```
cd-cleanup summary:
  Finalizers removed:          N ClusterDeployments
  CDs deleted:                 N (stuck Provisioning >24h)
  Skipped (state changed):     N
  Failed:                      N
```

---

### `clusterpool-cleanup:cc-resource-cleanup`

Cleans up orphaned AWS resources left behind by cluster claims on the collective, using
hiveutil's `aws-tag-deprovision`.

**Permissions:**
- Collective cluster read (to cross-reference live ClusterDeployments)
- AWS write credentials (prompted immediately before first deletion)

**Steps:**
1. Pre-flight:
   - Verify collective cluster access — attempt `kubectl get clusterpool -n app`.
     If it fails, prompt: `"Please log in first: oc login <api-url>"` and exit.
   - Check hiveutil binary exists; prompt for path if not found at default
     (`~/DEV/openshift/hive/bin/hiveutil`).
2. Check hiveutil git status — if behind origin, prompt:
   `"hiveutil is out of date. Update before continuing? (y/n)"`.
   If yes: `git pull` + `make build-hiveutil`.
3. Scan AWS across all regions for `kubernetes.io/cluster/*` tagged resource groups
   (via `aws resourcegroupstaggingapi get-tag-keys` + `get-resources`). Cross-reference
   each infra ID against live ClusterDeployments on the collective. Flag groups with no
   corresponding active CD as orphaned.
4. Present expand/select/deselect interface.
5. Prompt for AWS write profile; verify with `aws sts get-caller-identity`.
6. Single confirm before performing any deletions.
7. Run `hiveutil aws-tag-deprovision <tag>=owned --region <region>` for each confirmed
   item. Per-item safety re-check immediately before each call (re-verify infra ID is
   still not claimed by any active CD; skip if claimed).
8. Output summary.

**Summary:**
```
cc-resource-cleanup summary:
  Resource groups cleaned:     N (via hiveutil)
  Skipped (state changed):     N
  Failed:                      N
```

---

### `clusterpool-cleanup:investigate-orphans`

Run after `cd-cleanup` and `cc-resource-cleanup` to scan for anything still orphaned
across all resource types. Scans the shared AWS account broadly — including resources
from outside the collective/clusterpool scope (e.g. ROSA-based ACM hubs). Produces a
human-readable report and a structured manifest at `/tmp/clusterpool-cleanup-manifest.json`.

**Permissions:**
- AWS read-only credentials (hard dependency)
- Collective cluster read (soft dependency — if unavailable, ClusterDeployment
  cross-referencing is skipped and the user is warned; ROSA bucket checks via AWS
  still run)

**Steps:**
1. Pre-flight:
   - Prompt for AWS read-only profile; verify with `aws sts get-caller-identity`.
   - Attempt collective cluster access (`kubectl get clusterpool -n app`).
     If unavailable: warn `"Collective cluster unreachable — ClusterDeployment
     cross-referencing will be skipped. ROSA bucket checks will still run."` Continue.
2. Check manifest field `cc_resource_cleanup_run`. If false or manifest absent: warn
   `"cc-resource-cleanup has not been run this session. Tagged AWS resources may still
   be present. Consider running clusterpool-cleanup:full instead."`
3. Scan for orphaned resources across all types (see Investigated Resource Types below).
4. Cross-reference each found resource against live ClusterDeployments on the collective
   (if collective is reachable).
5. Write human-readable report to stdout and manifest to
   `/tmp/clusterpool-cleanup-manifest.json` with `"cc_resource_cleanup_run": false`.

**No confirmation required** — read-only, no destructive actions.

**Summary:**
```
investigate-orphans summary:
  Resources scanned:            N
  Orphaned (high confidence):   N
  Orphaned (medium confidence): N
  Human review required:        N
  Manifest written to:          /tmp/clusterpool-cleanup-manifest.json
```

#### Investigated Resource Types

**AWS Resources (via `kubernetes.io/cluster/*` tags, all regions):**
- EC2 instances
- VPCs, subnets, route tables, internet gateways
- Security groups
- NAT gateways
- Elastic IPs
- Load balancers (ELB/NLB/ALB)
- S3 image registry buckets
- Route53 hosted zones

**IAM (global):**
- IAM roles and instance profiles tagged or named with cluster infra IDs

**S3 Buckets — OADP auto-generated (`managed-velero-backups-<uuid>`):**
- Get `velero.io/infrastructureName` tag from each bucket
- If infra name is `rosa-*`: check AWS EC2 tags (`kubernetes.io/cluster/<infraID>=owned`)
  and Route53 hosted zone for that infra ID. Both must be absent to flag as orphaned.
- If infra name matches a Hive naming pattern: cross-reference against collective
  ClusterDeployment infra IDs (if collective is reachable).
- If orphaned: flag for deletion (HIGH or MEDIUM confidence depending on check results).

**S3 Buckets — manually pre-created (e.g. `vb-velero-backup`):**
- No standardized tags — cannot reliably link to a cluster.
- Flagged as HUMAN REVIEW. Deselected by default in execute UI.
- User may select them for deletion after manual review, but no automated safety
  check can be performed. Deletion uses `aws s3 rb --force`. User is warned explicitly
  before the final confirm if any HUMAN REVIEW items are selected (see UI section).

**Collective ClusterDeployments (if collective reachable):**
- `DeprovisionFailed` → flag for finalizer removal
- Stuck `Provisioning` >24h → flag for deletion

#### Report Format Per Resource

Each flagged resource includes:
```
Resource:           managed-velero-backups-03c2d0d6-...
Type:               S3 bucket (OADP auto-generated velero backup)
Origin:             ROSA cluster rosa-yjcli-taeu-vtm4j — ACM hub with cluster-backup enabled
Created:            2026-02-14
Why orphaned:       No EC2 instances or Route53 hosted zone found for rosa-yjcli-taeu-vtm4j
                    — cluster has been removed from AWS
Confidence:         HIGH
Recommended action: Delete bucket
```

---

### `clusterpool-cleanup:cleanup-orphans`

Acts on a saved manifest from a prior `investigate-orphans` run.

**Permissions:**
- Collective cluster write
- AWS write credentials (prompted immediately before first deletion)

**Steps:**
1. Pre-flight:
   - Verify collective cluster access.
   - Load manifest from `/tmp/clusterpool-cleanup-manifest.json` (prompt for path if
     not found; path prompt is skipped when invoked via `full`).
2. Present expand/select/deselect interface grouped by confidence level.
   HUMAN REVIEW items are deselected by default but can be selected by the user
   after manual review.
3. Prompt for AWS write profile; verify with `aws sts get-caller-identity`.
4. If any HUMAN REVIEW items are selected, show warning before confirm:
   `"⚠ N selected items have no automated safety check (no cluster linkage).
   Expand to review before proceeding."`
5. Single confirm before performing any deletions. Confirm message notes if
   HUMAN REVIEW items are included:
   `"Proceed with selected items? (includes N items with no safety check) (y/n)"`
6. Execute selected actions:
   - Standard items: per-item safety re-check immediately before each action.
   - HUMAN REVIEW items: deleted directly via `aws s3 rb --force`, no safety check.
   Skip and report standard items if state has changed.
7. Output summary.

**Summary:**
```
cleanup-orphans summary:
  Cleaned:                     N items
  Skipped (state changed):     N items
  Failed:                      N items
```

---

### `clusterpool-cleanup:full`

Convenience skill that runs all four steps in sequence.

**Order:**
1. `cd-cleanup`
2. `cc-resource-cleanup`
3. `investigate-orphans`
4. `cleanup-orphans`

**Permissions:** All of the above. AWS credentials are prompted at the point they are
first needed — not upfront:
- AWS write profile: prompted before first deletion in `cc-resource-cleanup`, reused for `cleanup-orphans`
- AWS read-only profile: prompted at start of `investigate-orphans`

**Confirmation points (3 total):**
1. Before `cd-cleanup` performs any deletions
2. Before `cc-resource-cleanup` performs any deletions
3. Before `cleanup-orphans` performs any deletions

`investigate-orphans` writes the manifest to `/tmp/clusterpool-cleanup-manifest.json` and
`cleanup-orphans` reads from that path automatically, skipping the path prompt.

**Summary:** Aggregates all four step summaries:
```
full summary:
  CD objects cleaned:          N
  AWS resource groups cleaned: N
  Remaining orphans found:     N
  Remaining orphans cleaned:   N
  Skipped (state changed):     N
  Failed:                      N
```

---

## UI — Expand/Select/Deselect Interface

Used by `cd-cleanup`, `cc-resource-cleanup`, and `cleanup-orphans` before any destructive action.

```
=== Cleanup Plan ===

[HIGH CONFIDENCE]
 [1] ✓  14 OADP velero buckets from deleted ROSA clusters
 [2] ✓   3 image registry buckets (DeprovisionFailed CDs)
 [3] ✓   2 Collective ClusterPool AWS resource cleanup leftovers

[MEDIUM CONFIDENCE]
 [4] ✓   5 DeprovisionFailed ClusterDeployments (finalizer removal)
 [5] ✓   2 Provisioning CDs stuck >24h

[HUMAN REVIEW REQUIRED — no automated safety check]
 [6] ✗   3 manually-named velero buckets (deselected by default)

Commands: <number> to toggle group, e<number> to expand/collapse,
          <number><letter> to toggle individual item (e.g. 1a), Enter to proceed
> e1

  [1a] ✓  managed-velero-backups-03c2d0d6-...
           Origin: ROSA cluster rosa-yjcli-taeu-vtm4j — ACM hub, cluster-backup enabled
           Created: 2026-02-14
           Why orphaned: No EC2/Route53 found for infra ID rosa-yjcli-taeu-vtm4j
  [1b] ✓  managed-velero-backups-0c236023-...
           ...

> 1b     (deselect individual item)
  [1b] ✗  managed-velero-backups-0c236023-... (deselected)

> 6      (select HUMAN REVIEW group)
  [6] ✓   3 manually-named velero buckets

  ⚠ These buckets have no standardized tags linking them to a cluster.
    No automated safety check can be performed. Expand (e6) to review each
    bucket before proceeding.

> (Enter)

⚠ Proceeding with 3 items that have no automated safety check.
Proceed with selected items? (y/n)
> y
```

- All items except HUMAN REVIEW are selected by default
- HUMAN REVIEW items are deselected by default but selectable; warning shown when selected
- Groups can be toggled as a whole or expanded to toggle individual items
- Single confirm before performing any deletions

---

## Knowledge Base

The skills maintain a local knowledge base in the `knowledge/` directory of the repo.
This accumulates learnings across runs to improve orphan detection over time.

```
knowledge/
  orphan-patterns.md       — confirmed patterns indicating a resource is orphaned
  active-signatures.md     — known active resource signatures to avoid false positives
  run-history/
    YYYY-MM-DD-run.md      — per-run summary: what was found, cleaned, and learned
```

**How it works:**
- `investigate-orphans` reads all of `knowledge/` at startup to inform its reasoning,
  increasing confidence on resources that match known patterns
- After `cleanup-orphans` completes, Claude appends a run summary to `run-history/` and
  updates `orphan-patterns.md` and `active-signatures.md` with any new patterns learned
  from user decisions (e.g. a resource type/naming pattern consistently confirmed orphaned)
- Claude may also update the knowledge base mid-run if it encounters something notable

**Sharing:**
The knowledge base is local-only by default. After each run, you decide what to commit
and push. Generic patterns (e.g. "managed-velero-backups-* with no matching EC2 tags are
orphaned") are safe to share. Sensitive specifics (infra IDs, account numbers, cluster
names) should remain local. This is left to your discretion per run.

---

## Pre-flight Check Summary

| Check | `cd-cleanup` | `cc-resource-cleanup` | `investigate-orphans` | `cleanup-orphans` |
|---|---|---|---|---|
| Collective cluster access | hard | hard | soft | hard |
| AWS read-only profile | — | — | hard | — |
| AWS write profile | — | before deletions | — | before deletions |
| hiveutil binary | — | hard | — | — |

**Hard dependency**: skill exits if check fails.
**Soft dependency**: skill continues with degraded functionality and warns the user.

Collective cluster login prompt: `"Please log in first: oc login <api-url>"`.
No hardcoded usernames, context names, or account-specific values anywhere in the skills.
