# Orphan Patterns

Confirmed patterns indicating a resource is orphaned. Claude uses these to increase confidence when flagging resources.

## S3 Buckets

### OADP auto-generated velero backup buckets (`managed-velero-backups-<uuid>`)
- Tagged with `velero.io/infrastructureName=<infraID>`
- If `infraID` starts with `rosa-`: orphaned when BOTH of these are absent:
  - No EC2 resources tagged `kubernetes.io/cluster/<infraID>=owned` in **any region** — use
    `get-tag-keys` across all regions, NOT just the region filter (ROSA clusters can be in any region
    and the S3 bucket location is unrelated to where the cluster ran)
  - No Route53 hosted zone matching `<infraID>` (Route53 is already global)
- If `infraID` matches Hive naming (e.g. `app-prow-*`): orphaned when not present in collective ClusterDeployment infraID list
- Confidence: HIGH when both EC2 and Route53 checks are negative

### Manually pre-created velero buckets (e.g. `vb-velero-backup`, `se-velero-backup`)
- No standardized tags — cannot be reliably linked to a cluster
- Flag as HUMAN REVIEW only; never auto-delete

## AWS Tagged Resource Groups (`kubernetes.io/cluster/<infraID>=owned`)

- If `infraID` is not present in any live ClusterDeployment on the collective: likely orphaned
- Cross-reference with `cc-resource-cleanup` results — if hiveutil already ran, these should be gone
- **For confidence classification rules, see `knowledge/resource-classification-rules.md`** — rules
  are shared with `cc-resource-cleanup` and defined there to avoid duplication.

## IAM Roles and Instance Profiles

- Named with infra ID pattern (e.g. `<infraID>-*` or `*-<infraID>`)
- If no corresponding active CD exists: orphaned
- Confidence: MEDIUM (IAM names are not always deterministic)

## Route53 Hosted Zones

- Named `<infraID>.<base-domain>` or similar
- If no EC2 resources exist for the same infraID: orphaned
- Confidence: MEDIUM (zone may outlive cluster during decommission window)

## Stale Tag Keys (Alphanumeric ROSA/HCP IDs)

- Alphanumeric infra IDs (e.g. `2llh73diqjubeu6ds5gsajab6u8vj6ep`) appear in `get-tag-keys` output with 0 resources
- These are stale entries in the AWS tag key index left after cluster deletion
- Not actionable — no actual resources exist to clean up
- Do NOT flag as orphans; skip entirely

## Partially Cleaned Hive Clusters (VPC Networking Remnants)

- app-prow-* clusters deprovisioned incompletely often leave behind VPC networking resources
  even after EC2 instances are removed: subnets, NAT gateways, EIPs, internet gateways, VPCs
- IAM master/worker roles and instance profiles also persist after instance cleanup
- Confidence: HIGH when no matching CD and only networking resources remain
- Action: run cc-resource-cleanup (hiveutil aws-tag-deprovision) for EC2 resources, then delete IAM manually
