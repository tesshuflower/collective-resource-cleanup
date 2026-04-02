---
name: clusterpool-cleanup:investigate-orphans
description: Autonomously investigate orphaned AWS resources from collective ClusterPool deployments. Scans broadly, reasons about resource relationships, and produces a report and manifest for cleanup-orphans to act on. Read-only — no destructive actions.
---

# investigate-orphans

## Overview

Before starting, tell the user:

> **investigate-orphans** will:
> 1. Connect to the collective cluster and load all active ClusterDeployments
> 2. Verify AWS read-only credentials
> 3. Broadly scan AWS resources across all regions — EC2, S3, IAM, Route53, and more
> 4. Reason about relationships between resources to identify orphans with confidence levels
> 5. Print a detailed report and write a manifest to `/tmp/clusterpool-cleanup-manifest.json`
>
> Read-only — no destructive actions. Run `cleanup-orphans` to act on the results.

## Pre-flight

1. Determine repo root: run `git rev-parse --show-toplevel` — store as REPO_ROOT.
2. Follow the steps in `skills/clusterpool-cleanup/_preflight-aws-readonly.md` to verify AWS read-only credentials. Store the profile as AWS_READ_PROFILE.
3. Connect to the collective cluster:
   - Set `KUBECONFIG=~/.kube/collective` and run `oc whoami`.
   - If it fails: run `oc login --web <collective_url from config, or prompt>` and retry.
   - If still fails: STOP — tell the user "ERROR: Collective cluster unreachable. Cannot safely assign confidence levels without ClusterDeployment data — aborting to avoid false HIGH/MEDIUM findings that could lead to deletion of active clusters."
   - Load all live CDs: `KUBECONFIG=~/.kube/collective bash -c 'set -o pipefail; source <REPO_ROOT>/scripts/lib/collective.sh && get_live_infra_ids'`
   - If this command fails or returns empty output: STOP — tell the user "ERROR: Could not load ClusterDeployments from collective. Aborting." (no clusterset filter — must protect active clusters regardless of who owns them).

## Filters

Ask the user for an optional region filter before investigating:

```
Region filter:
  1) No filter (scan all regions)
  2) Enter a region substring (e.g. "us-east")
```
Wait for selection. If 2, ask "Region substring:" and wait for input. Store as REGION_FILTER (empty if 1).

Apply throughout the investigation: skip any region that does not contain REGION_FILTER as a substring (if set).

## Load knowledge base

Read all files in `<REPO_ROOT>/knowledge/`:
- `orphan-patterns.md` — confirmed patterns indicating a resource is orphaned
- `active-signatures.md` — known active resource signatures to avoid false positives
- `run-history/*.md` — past run summaries (if any)

Use this knowledge to inform confidence assessments throughout the investigation.

## Investigate

This is the core of the skill. Investigate broadly and intelligently. The goal is to find AWS resources that are no longer associated with any active cluster.

### Ground truth

Build the set of active infra IDs:
- From live ClusterDeployments on the collective (if available)
- From EC2 tag keys that have been recently active (large resource counts suggest active clusters)

### AWS sweep

Enumerate all AWS regions: `aws ec2 describe-regions --profile <AWS_READ_PROFILE> --region us-east-1 --output json`

Skip any region that does not contain REGION_FILTER as a substring (if set).

For each region, gather:
- Tag keys matching `kubernetes.io/cluster/*`: `aws resourcegroupstaggingapi get-tag-keys --region <region> --profile <AWS_READ_PROFILE> --output json`
- For each infra ID found: check if it's in the active set

For any infra ID NOT in the active set: investigate further using the rules in
`knowledge/resource-classification-rules.md`. Specifically:
- How many resources are tagged with it? `aws resourcegroupstaggingapi get-resources --region <region> --profile <AWS_READ_PROFILE> --tag-filters Key=kubernetes.io/cluster/<infraID>,Values=owned --output json`
- What types of resources? (EC2 instances, VPCs, security groups, EIPs, NAT gateways, load balancers)
- Apply Step 2 from `resource-classification-rules.md`: look up the IAM master instance profile for
  every non-active infraID — `aws iam get-instance-profile --instance-profile-name <infraID>-master-profile --profile <AWS_READ_PROFILE>` — and use `CreateDate` as the primary age signal. Skip infraIDs whose profile is ≤ 12h old (possibly in-flight). This applies regardless of region filter since IAM is global.

### S3 investigation

List all S3 buckets: `aws s3 ls --profile <AWS_READ_PROFILE>`

For each bucket:
- If named `managed-velero-backups-*`: get tags `aws s3api get-bucket-tagging --bucket <name> --profile <AWS_READ_PROFILE>`
  - Get the `velero.io/infrastructureName` tag value
  - Check if that infra ID is active:
    - For `rosa-*` infra IDs: check EC2 tags across **all regions** (do NOT apply the REGION_FILTER — the
      S3 bucket location is unrelated to where the ROSA cluster ran) AND check Route53 (already global)
    - For Hive-style infra IDs (e.g. `app-prow-*`): check collective ClusterDeployment list
  - If no active cluster found:
    - Determine the bucket's effective age using whichever date is most recent:
      - Last write date (from `aws s3api list-objects-v2 --bucket <name> --query "sort_by(Contents, &LastModified)[-1].LastModified" --output text --profile <AWS_READ_PROFILE>`)
      - Bucket creation date (from `aws s3api list-buckets`, already fetched above)
      - If the bucket has objects: effective_date = max(last_write, creation_date)
      - If the bucket is empty: effective_date = creation_date
      - Note: empty does not mean never written to — objects may have been deleted
    - If effective_date is within the last **7 days**: flag as **HUMAN_REVIEW** — bucket is
      too recent to confidently classify; include the effective date and its source in the reason
    - If effective_date is more than 7 days ago: check Route53 for an active zone matching
      the cluster name (active ROSA HCP clusters always have a
      `rosa.<cluster-name>.<shard>.openshiftapps.com` zone)
      - If a matching zone exists: flag as **HUMAN_REVIEW** — cluster may still be active
      - If no matching zone: flag as likely orphaned (HIGH)
- For other buckets: use judgment — look at naming patterns, tags, and size/age if relevant
  - If clearly cluster-related but no standardized tags: flag as HUMAN REVIEW

### IAM investigation

Note: the per-infraID `get-instance-profile` CreateDate check is already performed as part of the
AWS sweep above (Step 2 of `resource-classification-rules.md`). The following is for discovering
IAM resources that may not appear in the tag sweep (e.g. profiles/roles whose tags weren't indexed).

List IAM roles: `aws iam list-roles --profile <AWS_READ_PROFILE>`
List instance profiles: `aws iam list-instance-profiles --profile <AWS_READ_PROFILE>`

For each role/profile whose name contains an infra ID pattern not already covered by the sweep:
- Check if that infra ID is active
- If not: flag as potentially orphaned (MEDIUM confidence — IAM names aren't always deterministic)

### Route53 investigation

List hosted zones: `aws route53 list-hosted-zones --profile <AWS_READ_PROFILE>`

For zones that appear cluster-related (named after an infra ID or cluster):
- Check if the corresponding cluster is still active
- If not: flag as potentially orphaned

### Reasoning about relationships

As you investigate, reason about connections between resources:
- A VPC with no EC2 instances, no active cluster tag, and a CIDR in the range Hive typically uses → likely orphaned
- An IAM role named after an infra ID that has no tagged EC2 resources → likely orphaned
- An S3 bucket from a ROSA cluster with no Route53 zone → likely orphaned
- Follow threads: if you find something suspicious, query deeper to understand it

You are not limited to the resource types listed above. If you discover other potentially orphaned resources while investigating, investigate them too.

### Confidence levels

For AWS tagged resource groups, apply the rules from `knowledge/resource-classification-rules.md`.
In particular: **HIGH confidence requires a confirmed IAM `CreateDate` > 12h** (Step 2). If the
IAM profile is not found (null), the age is unknown — classify as **POSSIBLY ORPHANED** at most,
never HIGH. The history file (Step 2b) is maintained by `cc-resource-cleanup`'s scan script; since
`investigate-orphans` does not update it, do not rely on it for promotion to HIGH here.

For all other resource types (S3, IAM roles, Route53), assign one of:
- **HIGH**: IAM CreateDate confirmed > 12h AND multiple independent checks confirm orphaned (e.g. no EC2 + no Route53 + no CD)
- **POSSIBLY ORPHANED**: no EC2/active signals found but age not confirmed via IAM
- **MEDIUM**: Partial evidence (e.g. no CD but Route53 still present — cluster may be mid-decommission)
- **HUMAN REVIEW**: Cannot be safely auto-categorized (e.g. manually-named buckets with no cluster tags)

## Write report

Print a human-readable report to the terminal:

```
=== investigate-orphans Report ===
Generated: <timestamp>
AWS account: <account-id from sts get-caller-identity>
Collective: connected

--- HIGH CONFIDENCE ---
[list each finding with: resource name/type, why orphaned, recommended action]

--- MEDIUM CONFIDENCE ---
[list each finding]

--- HUMAN REVIEW ---
[list each finding with: what it is, why it couldn't be auto-categorized]

--- Summary ---
  High confidence:   N
  Medium confidence: N
  Human review:      N
  Manifest written:  /tmp/clusterpool-cleanup-manifest.json
```

## Write manifest

Write `/tmp/clusterpool-cleanup-manifest.json` using `scripts/lib/manifest.sh` via its CLI dispatch
(do NOT source the file — sourcing fails in zsh):

```bash
bash <REPO_ROOT>/scripts/lib/manifest.sh manifest_init /tmp/clusterpool-cleanup-manifest.json
```

For each finding, add an item. With many findings (10+), write all items in a single Python script
rather than calling `manifest_add_item` once per item (67 subprocess calls is very slow):

```python
import json, datetime

items = [
    # one dict per finding
    {"id": "...", "type": "...", ...},
]
manifest = {
    "version": "1",
    "created_at": datetime.datetime.utcnow().isoformat() + "Z",
    "cc_resource_cleanup_run": False,
    "items": items,
}
with open("/tmp/clusterpool-cleanup-manifest.json", "w") as f:
    json.dump(manifest, f, indent=2)
```

For small numbers of findings, the CLI dispatch is fine:
```bash
bash <REPO_ROOT>/scripts/lib/manifest.sh manifest_add_item /tmp/clusterpool-cleanup-manifest.json '<json>'
```

Where each item JSON includes:
- `id`: unique string
- `type`: resource type (e.g. "s3_bucket", "iam_role", "aws_tagged_resources", "route53_zone")
- `name`: resource name/identifier
- `region`: AWS region (or "global" for IAM/S3)
- `confidence`: "HIGH", "MEDIUM", or "HUMAN_REVIEW"
- `reason`: why it's flagged as orphaned
- `recommended_action`: what cleanup-orphans should do

Set the `cc_resource_cleanup_run` field to false (cleanup-orphans will check this).

After writing all items:
```bash
bash <REPO_ROOT>/scripts/lib/manifest.sh manifest_set_cc_resource_cleanup_run /tmp/clusterpool-cleanup-manifest.json false
```

## Update knowledge base

After completing the investigation, append a run summary to `<REPO_ROOT>/knowledge/run-history/`:
```bash
# Create file: YYYY-MM-DD-run.md
```

Include: date, resources scanned, findings summary, any new patterns noticed.

If you discovered new orphan patterns or active signatures not in the knowledge base, update `knowledge/orphan-patterns.md` or `knowledge/active-signatures.md` accordingly.
