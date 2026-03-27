# Resource Classification Rules

Shared rules used by both `cc-resource-cleanup` and `investigate-orphans` to classify tagged
AWS resource groups. Apply these consistently across both skills.

## AWS Tagged Resource Groups (`kubernetes.io/cluster/<infraID>=owned`)

### Step 1 — Is the infra ID active?

- If the infra ID matches a live ClusterDeployment on the collective: **ACTIVE — skip entirely**
- If not found in any live CD: proceed to step 2

### Step 2 — Check IAM instance profile age (always do this)

For every infraID not in the active set, look up its IAM instance profile directly — regardless
of region filter or whether IAM appeared in the tag scan:

```bash
aws iam get-instance-profile --instance-profile-name <infraID>-master-profile --profile <PROFILE>
```

IAM is a global service. This call always works regardless of region. Use the result as follows:

- **Found, `CreateDate` > 24h ago**: cluster is definitely old — not an in-progress provision.
  Proceed to Step 3. (Provisioning takes well under an hour; >24h means this infraID is abandoned.)
- **Found, `CreateDate` ≤ 24h ago**: cluster may still be provisioning. Mark as **SKIP (possibly
  in-flight)** and do not include in cleanup plan. Re-scan later.
- **Not found**: instance profile was already deleted or never created. Either Hive partially cleaned
  up IAM before the tag-group scan ran (VPC remnants are safe to clean), or the install failed so
  early that IAM was never created (resources are genuine orphans). Proceed to Step 3.

This check resolves the ambiguity of VPC-only resource groups (no EC2, no IAM in scan results)
where there is no other timestamp signal available.

### Step 3 — Classify by resource profile

**HIGH confidence (safe to clean):**
- Resource count ≤ 10: almost certainly a tag stub from an incompletely deprovisioned cluster
- Resource count > 10 **with no running EC2 instances** (only networking/storage remnants such as
  subnets, NAT gateways, EIPs, IGWs, VPCs, EBS volumes): incompletely deprovisioned cluster —
  still HIGH confidence

**HUMAN REVIEW (do not auto-clean):**
- Resource count > 10 **and has running EC2 instances**: likely an active or manually-created
  cluster not registered with the collective. Absence from collective CDs may mean it was created
  outside clusterpools, not that it is orphaned.
- When in doubt about EC2 presence: check `ec2/instance` in the resource type breakdown before
  classifying

### Rationale

The IAM `CreateDate` check is the primary age signal — it's a reliable, global, single-call way to
determine whether an infraID could belong to a currently-provisioning cluster. Provisioning takes
under an hour; anything older than 24h is definitively not in-flight.

The ≤10 / >10 resource count split is a useful secondary signal but is too blunt on its own. The
real danger signal is running EC2 instances — a cluster with active compute is likely in use. A
cluster with only VPC networking remnants, even if >10 resources, is a safe cleanup target once
confirmed old via IAM age.
