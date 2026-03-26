# Active Resource Signatures

Known patterns indicating a resource is ACTIVE (not orphaned). Claude uses these to avoid false positives.

## ClusterDeployments

- Any CD in `Provisioned` state with a non-empty infraID is active
- CDs in `Provisioning` state less than 24 hours old are likely still provisioning (not stuck)
- CDs in `DeprovisionFailed` state have AWS credentials issues — AWS resources may still exist

## S3 Buckets

- Buckets with recent (< 7 days) write activity may be from an in-progress cluster backup
- `velero.io/infrastructureName` tag pointing to an infraID with live EC2 resources = active

## AWS Tagged Resources

- Any tag group where the infraID matches a live CD on the collective = active
- Tag groups with > 50 resources are more likely to be active (active clusters have many resources)

## IAM

- IAM roles attached to running EC2 instances = active
- Instance profiles associated with running instances = active

## Route53 Zones Created by OCP Installer (Hive Clusters)

- The DNS suffix in OCP-installer-created Route53 zone names is randomly generated — it does NOT
  match the CD's infra ID suffix
- Example: CD `app-prow-small-aws-42-sptgz` creates zone `app-prow-small-aws-421-west2-pthps.dev11...`
  where `pthps` is random and unrelated to `sptgz`
- To determine which CD owns a zone: check the CallerReference field
  - Format: `<cd-name>-<random>` (e.g. `app-prow-small-aws-42-sptgz-88jbv`)
  - If CallerReference contains a CD name that is in the active list → zone is ACTIVE
- Never flag a zone as orphaned based on the DNS suffix alone

## ROSA HCP Clusters (Alphanumeric Infra IDs)

- Alphanumeric infra IDs (e.g. `2lrqfndplc5l3hfj51liso0o540kpm2a`) are ROSA HCP cluster identifiers —
  they will NOT appear in collective ClusterDeployments (not Hive-managed)
- Active ROSA HCP clusters have Route53 zones in the form:
  - `rosa.<cluster-name>.<shard>.openshiftapps.com`
  - `<cluster-name>.hypershift.local`
- EC2 instance names follow the pattern `<cluster-name>-workers-*`
- Always check Route53 before flagging an alphanumeric ID — a matching zone = cluster is still active
