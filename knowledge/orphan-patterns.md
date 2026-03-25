# Orphan Patterns

Confirmed patterns indicating a resource is orphaned. Claude uses these to increase confidence when flagging resources.

## S3 Buckets

### OADP auto-generated velero backup buckets (`managed-velero-backups-<uuid>`)
- Tagged with `velero.io/infrastructureName=<infraID>`
- If `infraID` starts with `rosa-`: orphaned when BOTH of these are absent:
  - No EC2 resources tagged `kubernetes.io/cluster/<infraID>=owned` in any region
  - No Route53 hosted zone matching `<infraID>`
- If `infraID` matches Hive naming (e.g. `app-prow-*`): orphaned when not present in collective ClusterDeployment infraID list
- Confidence: HIGH when both EC2 and Route53 checks are negative

### Manually pre-created velero buckets (e.g. `vb-velero-backup`, `se-velero-backup`)
- No standardized tags — cannot be reliably linked to a cluster
- Flag as HUMAN REVIEW only; never auto-delete

## AWS Tagged Resource Groups (`kubernetes.io/cluster/<infraID>=owned`)

- If `infraID` is not present in any live ClusterDeployment on the collective: likely orphaned
- Cross-reference with `cc-resource-cleanup` results — if hiveutil already ran, these should be gone
- Confidence: HIGH when infraID has no matching CD and resource count > 0

## IAM Roles and Instance Profiles

- Named with infra ID pattern (e.g. `<infraID>-*` or `*-<infraID>`)
- If no corresponding active CD exists: orphaned
- Confidence: MEDIUM (IAM names are not always deterministic)

## Route53 Hosted Zones

- Named `<infraID>.<base-domain>` or similar
- If no EC2 resources exist for the same infraID: orphaned
- Confidence: MEDIUM (zone may outlive cluster during decommission window)
