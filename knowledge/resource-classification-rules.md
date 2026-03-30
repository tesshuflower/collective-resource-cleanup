# Resource Classification Rules

Shared rules used by both `cc-resource-cleanup` and `investigate-orphans` to classify tagged
AWS resource groups. Apply these consistently across both skills.

## AWS Tagged Resource Groups (`kubernetes.io/cluster/<infraID>=owned`)

Apply the following steps in order. Stop at the first match.

### Step 1 — Is the infra ID active?

If the infra ID matches a live ClusterDeployment on the collective: **SKIP — do not include in plan.**

### Step 2 — Check IAM instance profile age

Look up the IAM master instance profile directly (IAM is global — works regardless of region filter):

```bash
aws iam get-instance-profile --instance-profile-name <infraID>-master-profile --profile <PROFILE>
```

- **Found, `CreateDate` ≤ 24h ago**: cluster may still be provisioning → **SKIP**
- **Found, `CreateDate` > 24h ago**: age confirmed via IAM → proceed to Step 3
- **Not found**: no IAM age signal → check history file (Step 2b)

### Step 2b — History file fallback (when IAM not found)

Read `~/.cache/collective-resource-cleanup/known-infra-ids.json`.

The history file only tracks infraIDs with null IAM — entries where we believe cleanup is needed
but cannot confirm age. IAM-confirmed infraIDs are never written to history (their age comes
directly from `CreateDate`). A null IAM profile could indicate a cluster that failed before IAM
was created, or one that was already cleaned up (IAM deleted during deprovision). The history
file is how we distinguish "been sitting here a while" from "just appeared today."

Update `last_seen_as_candidate` to now for any infraID already in the file. Add new infraIDs with
both `first_seen_as_candidate` and `last_seen_as_candidate` set to now. Expire entries where
`last_seen_as_candidate` > 120 days ago.

- **`first_seen_as_candidate` > 24h ago**: seen as a cleanup candidate long enough → proceed to Step 3
- **`first_seen_as_candidate` ≤ 24h ago, or not in history (just added)**: age not yet confirmed → **POSSIBLY ORPHANED**

### Step 3 — Check for EC2 instances

Check `resource_types` from the scan output for the presence of `instance`:

- **`instance` present**: cluster may be active or hibernated → **HUMAN REVIEW**
- **No `instance`**: → **HIGH confidence**

## Confidence levels

| Level | Meaning | Default in plan |
|-------|---------|-----------------|
| HIGH | Age confirmed (IAM or history as candidate), no EC2 | Selected |
| POSSIBLY ORPHANED | No EC2, but not seen long enough as a cleanup candidate — re-run later | Deselected |
| HUMAN REVIEW | EC2 present | Deselected |
| SKIP | Active CD, or IAM ≤ 24h old | Not shown |

## History file

Path: `~/.cache/collective-resource-cleanup/known-infra-ids.json`

Only infraIDs with null IAM are tracked here. infraIDs with a confirmed IAM profile are never
written to the history file — their age is read directly from `CreateDate`.

Format:
```json
{
  "app-prow-small-aws-42-6nk95": {
    "first_seen_as_candidate": "2026-03-26T10:00:00Z",
    "last_seen_as_candidate": "2026-03-27T14:00:00Z"
  }
}
```

- Update `last_seen_as_candidate` on every scan that finds the infraID with null IAM
- Remove entries where `last_seen_as_candidate` > 120 days ago (expired)
- Remove entries after successful cleanup by cc-resource-cleanup

## Notes

- The tagging API includes terminated instances in `instance` resource type counts. We do not
  verify actual instance state — anything showing `instance` goes to HUMAN REVIEW. Terminated
  instances will eventually drop out of the tagging index on their own.
- Hibernated clusters have stopped (not terminated) instances — they correctly show `instance`
  and land in HUMAN REVIEW.
- POSSIBLY ORPHANED entries (null IAM) graduate to HIGH on a future scan once
  `first_seen_as_candidate` > 24h ago. Users can re-run the scan later to act on them.
