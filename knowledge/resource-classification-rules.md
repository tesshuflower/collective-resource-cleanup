# Resource Classification Rules

Shared rules used by both `cc-resource-cleanup` and `investigate-orphans` to classify tagged
AWS resource groups. Apply these consistently across both skills.

## AWS Tagged Resource Groups (`kubernetes.io/cluster/<infraID>=owned`)

### Step 1 — Is the infra ID active?

- If the infra ID matches a live ClusterDeployment on the collective: **ACTIVE — skip entirely**
- If not found in any live CD: proceed to step 2

### Step 2 — Classify by resource profile

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

The ≤10 / >10 split (from cc-resource-cleanup) is a useful first pass but is too blunt on its own.
The real danger signal is running EC2 instances — a cluster with active compute is likely in use.
A cluster with only VPC networking remnants, even if >10 resources, is a safe cleanup target.
