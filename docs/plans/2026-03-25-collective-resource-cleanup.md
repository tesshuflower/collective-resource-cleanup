# Collective Resource Cleanup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement five Claude Code skills (`cd-cleanup`, `cc-resource-cleanup`, `investigate-orphans`, `cleanup-orphans`, `full`) backed by bash scan scripts to investigate and clean up orphaned AWS resources and Kubernetes objects from the collective ClusterPool environment.

**Architecture:** Hybrid — bash scripts handle deterministic data gathering (AWS API calls, kubectl queries, JSON output); Claude skills handle the interactive UI, confidence reasoning, knowledge base updates, and orchestration. Scripts are called by Claude via the Bash tool during skill execution. The manifest file (`/tmp/clusterpool-cleanup-manifest.json`) is the handoff between `investigate-orphans` and `cleanup-orphans`.

**Tech Stack:** Bash, AWS CLI, kubectl/oc, hiveutil, jq, python3, bats-core (testing), Claude Code superpowers skills (markdown)

**Spec:** `docs/specs/2026-03-25-clusterpool-cleanup-design.md`

---

## File Structure

```
collective-resource-cleanup/
  scripts/
    lib/
      preflight.sh         — pre-flight checks (AWS profile, collective access, namespace, hiveutil)
      aws.sh               — AWS query functions (tag scanning, S3, Route53, EC2, IAM)
      collective.sh        — collective cluster query functions (kubectl, ClusterDeployment scan)
      manifest.sh          — manifest read/write/update functions
    scan-cds.sh            — scan for stuck ClusterDeployments (DeprovisionFailed, stuck Provisioning)
    scan-cc-resources.sh   — scan AWS tagged resource groups vs live ClusterDeployments
    scan-orphans.sh        — full orphan scan across all resource types
  skills/
    clusterpool-cleanup/
      cd-cleanup.md        — Claude skill: ClusterDeployment cleanup
      cc-resource-cleanup.md — Claude skill: cluster claim AWS resource cleanup via hiveutil
      investigate-orphans.md — Claude skill: full orphan investigation
      cleanup-orphans.md   — Claude skill: act on manifest from investigate-orphans
      full.md              — Claude skill: orchestrate all four in sequence
  knowledge/
    orphan-patterns.md     — confirmed patterns indicating orphaned resources
    active-signatures.md   — known active resource signatures (avoid false positives)
    run-history/
      .gitkeep
  tests/
    lib/
      test_preflight.bats
      test_aws.bats
      test_collective.bats
      test_manifest.bats
    test_scan_cds.bats
    test_scan_cc_resources.bats
    test_scan_orphans.bats
    helpers/
      mock_aws.sh          — mock AWS CLI responses for testing
      mock_kubectl.sh      — mock kubectl responses for testing
```

Scripts output JSON to stdout. Skills call scripts via Bash tool, parse output, and drive the interactive UI.

---

## Phase 1: Foundation

### Task 1: Repo structure and test infrastructure

**Files:**
- Create: `scripts/lib/.gitkeep`
- Create: `skills/clusterpool-cleanup/.gitkeep`
- Create: `knowledge/orphan-patterns.md`
- Create: `knowledge/active-signatures.md`
- Create: `knowledge/run-history/.gitkeep`
- Create: `tests/helpers/mock_aws.sh`
- Create: `tests/helpers/mock_kubectl.sh`

- [ ] **Step 1: Verify bats-core is available**

```bash
bats --version
```
If not installed: `brew install bats-core`

- [ ] **Step 2: Create directory structure**

```bash
cd ~/DEV/tesshuflower/collective-resource-cleanup
mkdir -p scripts/lib skills/clusterpool-cleanup knowledge/run-history tests/lib tests/helpers
```

- [ ] **Step 3: Create knowledge base initial files**

`knowledge/orphan-patterns.md`:
```markdown
# Orphan Patterns

Patterns confirmed to indicate orphaned resources. Updated after each cleanup run.

## S3 Buckets

<!-- Example entry (add confirmed patterns below):
- Pattern: managed-velero-backups-* with velero.io/infrastructureName=rosa-* AND no EC2 tags or Route53 zone for that infra ID
  Confidence: HIGH
  Confirmed: YYYY-MM-DD
-->
```

`knowledge/active-signatures.md`:
```markdown
# Active Resource Signatures

Known signatures of active resources — do NOT flag these as orphaned.

<!-- Example entry:
- InfraID prefix: app-prow-small-aws-421-west2 → active pool as of YYYY-MM-DD
-->
```

- [ ] **Step 4: Create mock helpers**

`tests/helpers/mock_aws.sh`:
```bash
#!/usr/bin/env bash
# Mock AWS CLI for testing. Set MOCK_AWS_RESPONSES dir before sourcing.
# Fixture filename encoding: spaces→_, /→_, ,→_, =→_
aws() {
  local key="${*// /_}"
  key="${key//\//_}"
  key="${key//,/_}"
  key="${key//=/_}"
  local response_file="${MOCK_AWS_RESPONSES}/${key}.json"
  if [[ -f "$response_file" ]]; then
    cat "$response_file"
    return 0
  fi
  echo "No mock for: aws $*" >&2
  return 1
}
export -f aws
```

`tests/helpers/mock_kubectl.sh`:
```bash
#!/usr/bin/env bash
# Mock kubectl for testing.
kubectl() {
  local response_file="${MOCK_KUBECTL_RESPONSES}/${*// /_}.json"
  if [[ -f "$response_file" ]]; then
    cat "$response_file"
    return 0
  fi
  echo "No mock for: kubectl $*" >&2
  return 1
}
export -f kubectl
```

- [ ] **Step 5: Commit**

```bash
git add scripts/ skills/ knowledge/ tests/
git commit -m "chore: scaffold repo structure and test infrastructure"
```

---

### Task 2: Pre-flight library (`scripts/lib/preflight.sh`)

**Files:**
- Create: `scripts/lib/preflight.sh`
- Create: `tests/lib/test_preflight.bats`

- [ ] **Step 1: Write failing tests**

`tests/lib/test_preflight.bats`:
```bash
#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../../scripts/lib/preflight.sh"
  export MOCK_AWS_RESPONSES="${BATS_TEST_DIRNAME}/../fixtures/aws"
  export MOCK_KUBECTL_RESPONSES="${BATS_TEST_DIRNAME}/../fixtures/kubectl"
  source "${BATS_TEST_DIRNAME}/../helpers/mock_aws.sh"
  source "${BATS_TEST_DIRNAME}/../helpers/mock_kubectl.sh"
  mkdir -p "${BATS_TEST_DIRNAME}/../fixtures/aws"
  mkdir -p "${BATS_TEST_DIRNAME}/../fixtures/kubectl"
}

@test "verify_aws_profile: returns 0 when credentials valid" {
  echo '{"UserId":"AIDA123","Account":"999","Arn":"arn:aws:iam::999:user/test"}' \
    > "${BATS_TEST_DIRNAME}/../fixtures/aws/sts_get-caller-identity_--profile_test-profile.json"
  run verify_aws_profile "test-profile"
  [ "$status" -eq 0 ]
}

@test "verify_aws_profile: returns 1 when credentials invalid" {
  # No fixture = mock returns error
  run verify_aws_profile "bad-profile"
  [ "$status" -eq 1 ]
}

@test "verify_collective_access: returns 0 when cluster reachable" {
  mkdir -p "${BATS_TEST_DIRNAME}/../fixtures/kubectl"
  echo '{"items":[{"metadata":{"name":"app-pool"}}]}' \
    > "${BATS_TEST_DIRNAME}/../fixtures/kubectl/get_clusterpool_-n_app_-o_json.json"
  run verify_collective_access "app"
  [ "$status" -eq 0 ]
}

@test "verify_collective_access: returns 1 when cluster unreachable" {
  run verify_collective_access "app"
  [ "$status" -eq 1 ]
}

@test "verify_hiveutil: returns 0 when binary exists" {
  local tmpbin=$(mktemp)
  chmod +x "$tmpbin"
  run verify_hiveutil "$tmpbin"
  rm "$tmpbin"
  [ "$status" -eq 0 ]
}

@test "verify_hiveutil: returns 1 when binary missing" {
  run verify_hiveutil "/nonexistent/hiveutil"
  [ "$status" -eq 1 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
bats tests/lib/test_preflight.bats
```
Expected: all fail with "source: command not found" or similar.

- [ ] **Step 3: Implement `scripts/lib/preflight.sh`**

```bash
#!/usr/bin/env bash
# Pre-flight check functions for clusterpool-cleanup skills.

# Verify AWS profile credentials are valid.
# Usage: verify_aws_profile <profile-name>
# Returns: 0 if valid, 1 if invalid
verify_aws_profile() {
  local profile="$1"
  aws sts get-caller-identity --profile "$profile" &>/dev/null
}

# Verify collective cluster is reachable for the given namespace.
# Usage: verify_collective_access <namespace>
# Returns: 0 if reachable, 1 if not
verify_collective_access() {
  local namespace="$1"
  kubectl get clusterpool -n "$namespace" -o json &>/dev/null
}

# Verify hiveutil binary exists and is executable.
# Usage: verify_hiveutil <path>
# Returns: 0 if found, 1 if not
verify_hiveutil() {
  local path="$1"
  [[ -x "$path" ]]
}

# Prompt for and verify AWS profile. Exits with error message if invalid.
# Usage: prompt_aws_profile <suggested-default>
# Prints verified profile name to stdout.
prompt_and_verify_aws_profile() {
  local default="$1"
  local profile
  read -rp "AWS profile? (default: ${default}): " profile
  profile="${profile:-$default}"
  if ! verify_aws_profile "$profile"; then
    echo "ERROR: AWS credentials invalid for profile '${profile}'." >&2
    echo "Verify your credentials and try again." >&2
    return 1
  fi
  echo "$profile"
}

# Prompt for collective namespace and verify cluster access.
# Usage: prompt_collective_namespace <suggested-default>
# Prints verified namespace to stdout.
prompt_and_verify_collective_access() {
  local default="$1"
  local namespace
  read -rp "Collective cluster namespace? (default: ${default}): " namespace
  namespace="${namespace:-$default}"
  if ! verify_collective_access "$namespace"; then
    local api_url
    api_url=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null \
      || echo "<collective-api-url>")
    echo "ERROR: Cannot reach collective cluster in namespace '${namespace}'." >&2
    echo "Please log in first: oc login ${api_url}" >&2
    return 1
  fi
  echo "$namespace"
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
bats tests/lib/test_preflight.bats
```
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/preflight.sh tests/lib/test_preflight.bats tests/
git commit -m "feat: add pre-flight check library with tests"
```

---

### Task 3: Collective library (`scripts/lib/collective.sh`)

**Files:**
- Create: `scripts/lib/collective.sh`
- Create: `tests/lib/test_collective.bats`

- [ ] **Step 1: Write failing tests**

`tests/lib/test_collective.bats`:
```bash
#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../../scripts/lib/collective.sh"
  source "${BATS_TEST_DIRNAME}/../helpers/mock_kubectl.sh"
  export MOCK_KUBECTL_RESPONSES="${BATS_TEST_DIRNAME}/../fixtures/kubectl"
  mkdir -p "$MOCK_KUBECTL_RESPONSES"
}

@test "get_live_infra_ids: returns infra IDs of non-DeprovisionFailed CDs" {
  cat > "${MOCK_KUBECTL_RESPONSES}/get_clusterdeployment_--all-namespaces_-l_cluster.open-cluster-management.io_clusterset=app_-o_json.json" <<'EOF'
{"items":[
  {"spec":{"clusterMetadata":{"infraID":"infra-abc123"}},"status":{"provisionStatus":"Provisioned"}},
  {"spec":{"clusterMetadata":{"infraID":"infra-dead"}},"status":{"provisionStatus":"DeprovisionFailed"}}
]}
EOF
  run get_live_infra_ids "app"
  [ "$status" -eq 0 ]
  [[ "$output" == *"infra-abc123"* ]]
  [[ "$output" != *"infra-dead"* ]]
}

@test "get_deprovisioned_failed_cds: returns DeprovisionFailed CDs as JSON array" {
  cat > "${MOCK_KUBECTL_RESPONSES}/get_clusterdeployment_--all-namespaces_-l_cluster.open-cluster-management.io_clusterset=app_-o_json.json" <<'EOF'
{"items":[
  {"metadata":{"name":"cd-dead","namespace":"cd-dead"},"spec":{"clusterMetadata":{"infraID":"infra-dead"}},"status":{"provisionStatus":"DeprovisionFailed"}}
]}
EOF
  run get_deprovision_failed_cds "app"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cd-dead"* ]]
}

@test "get_stuck_provisioning_cds: only returns CDs stuck longer than threshold" {
  local old_time
  old_time=$(date -u -v-25H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u --date='25 hours ago' '+%Y-%m-%dT%H:%M:%SZ')
  local recent_time
  recent_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  cat > "${MOCK_KUBECTL_RESPONSES}/get_clusterdeployment_--all-namespaces_-l_cluster.open-cluster-management.io_clusterset=app_-o_json.json" <<EOF
{"items":[
  {"metadata":{"name":"stuck-cd","namespace":"stuck-cd","creationTimestamp":"${old_time}"},"status":{"provisionStatus":"Provisioning"}},
  {"metadata":{"name":"new-cd","namespace":"new-cd","creationTimestamp":"${recent_time}"},"status":{"provisionStatus":"Provisioning"}}
]}
EOF
  run get_stuck_provisioning_cds "app" 24
  [ "$status" -eq 0 ]
  [[ "$output" == *"stuck-cd"* ]]
  [[ "$output" != *"new-cd"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
bats tests/lib/test_collective.bats
```

- [ ] **Step 3: Implement `scripts/lib/collective.sh`**

```bash
#!/usr/bin/env bash
# Collective cluster query functions.

# Get infra IDs of all live (non-DeprovisionFailed) ClusterDeployments.
# Usage: get_live_infra_ids <namespace/clusterset>
# Prints one infra ID per line.
get_live_infra_ids() {
  local clusterset="$1"
  kubectl get clusterdeployment --all-namespaces \
    -l "cluster.open-cluster-management.io/clusterset=${clusterset}" \
    -o json 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
for cd in data.get('items', []):
    status = cd.get('status', {}).get('provisionStatus', '')
    if status != 'DeprovisionFailed':
        infra_id = cd.get('spec', {}).get('clusterMetadata', {}).get('infraID', '')
        if infra_id:
            print(infra_id)
"
}

# Get ClusterDeployments in DeprovisionFailed state as JSON array.
# Usage: get_deprovision_failed_cds <namespace/clusterset>
get_deprovision_failed_cds() {
  local clusterset="$1"
  kubectl get clusterdeployment --all-namespaces \
    -l "cluster.open-cluster-management.io/clusterset=${clusterset}" \
    -o json 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
results = []
for cd in data.get('items', []):
    if cd.get('status', {}).get('provisionStatus') == 'DeprovisionFailed':
        results.append({
            'name': cd['metadata']['name'],
            'namespace': cd['metadata']['namespace'],
            'infraID': cd.get('spec', {}).get('clusterMetadata', {}).get('infraID', ''),
        })
print(json.dumps(results))
"
}

# Get ClusterDeployments stuck in Provisioning for longer than threshold_hours.
# Usage: get_stuck_provisioning_cds <namespace/clusterset> <threshold_hours>
get_stuck_provisioning_cds() {
  local clusterset="$1"
  local threshold_hours="${2:-24}"
  kubectl get clusterdeployment --all-namespaces \
    -l "cluster.open-cluster-management.io/clusterset=${clusterset}" \
    -o json 2>/dev/null \
    | python3 -c "
import sys, json
from datetime import datetime, timezone, timedelta
data = json.load(sys.stdin)
threshold = datetime.now(timezone.utc) - timedelta(hours=${threshold_hours})
results = []
for cd in data.get('items', []):
    if cd.get('status', {}).get('provisionStatus') == 'Provisioning':
        ts = cd['metadata'].get('creationTimestamp', '')
        try:
            created = datetime.fromisoformat(ts.replace('Z', '+00:00'))
            if created < threshold:
                results.append({
                    'name': cd['metadata']['name'],
                    'namespace': cd['metadata']['namespace'],
                    'createdAt': ts,
                })
        except ValueError:
            pass
print(json.dumps(results))
"
}

# Get current state of a single ClusterDeployment.
# Usage: get_cd_state <namespace> <name>
# Prints provisionStatus to stdout.
get_cd_state() {
  local namespace="$1"
  local name="$2"
  kubectl get clusterdeployment -n "$namespace" "$name" \
    -o jsonpath='{.status.provisionStatus}' 2>/dev/null
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
bats tests/lib/test_collective.bats
```

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/collective.sh tests/lib/test_collective.bats
git commit -m "feat: add collective cluster query library with tests"
```

---

### Task 4: AWS library (`scripts/lib/aws.sh`)

**Files:**
- Create: `scripts/lib/aws.sh`
- Create: `tests/lib/test_aws.bats`

- [ ] **Step 1: Write failing tests**

`tests/lib/test_aws.bats`:
```bash
#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../../scripts/lib/aws.sh"
  source "${BATS_TEST_DIRNAME}/../helpers/mock_aws.sh"
  export MOCK_AWS_RESPONSES="${BATS_TEST_DIRNAME}/../fixtures/aws"
  mkdir -p "$MOCK_AWS_RESPONSES"
}

@test "get_aws_regions: returns list of regions" {
  cat > "${MOCK_AWS_RESPONSES}/ec2_describe-regions_--profile_ro_--output_json.json" <<'EOF'
{"Regions":[{"RegionName":"us-east-1"},{"RegionName":"us-west-2"}]}
EOF
  run get_aws_regions "ro"
  [ "$status" -eq 0 ]
  [[ "$output" == *"us-east-1"* ]]
  [[ "$output" == *"us-west-2"* ]]
}

@test "get_cluster_tag_keys: returns kubernetes.io/cluster/ tag keys for region" {
  cat > "${MOCK_AWS_RESPONSES}/resourcegroupstaggingapi_get-tag-keys_--region_us-east-1_--profile_ro_--output_json.json" <<'EOF'
{"TagKeys":["kubernetes.io/cluster/infra-abc123","other-tag"]}
EOF
  run get_cluster_tag_keys "ro" "us-east-1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"infra-abc123"* ]]
  [[ "$output" != *"other-tag"* ]]
}

@test "infra_id_has_ec2_resources: returns 0 when resources found" {
  cat > "${MOCK_AWS_RESPONSES}/resourcegroupstaggingapi_get-resources_--region_us-east-1_--profile_ro_--tag-filters_Key_kubernetes.io_cluster_infra-abc123_Values_owned_--output_json.json" <<'EOF'
{"ResourceTagMappingList":[{"ResourceARN":"arn:aws:ec2:us-east-1:999:instance/i-abc"}]}
EOF
  run infra_id_has_ec2_resources "ro" "us-east-1" "infra-abc123"
  [ "$status" -eq 0 ]
}

@test "infra_id_has_ec2_resources: returns 1 when no resources found" {
  cat > "${MOCK_AWS_RESPONSES}/resourcegroupstaggingapi_get-resources_--region_us-east-1_--profile_ro_--tag-filters_Key_kubernetes.io_cluster_infra-none_Values_owned_--output_json.json" <<'EOF'
{"ResourceTagMappingList":[]}
EOF
  run infra_id_has_ec2_resources "ro" "us-east-1" "infra-none"
  [ "$status" -eq 1 ]
}

@test "get_velero_bucket_infra_id: returns infrastructureName tag value" {
  cat > "${MOCK_AWS_RESPONSES}/s3api_get-bucket-tagging_--bucket_managed-velero-backups-abc_--profile_ro.json" <<'EOF'
{"TagSet":[{"Key":"velero.io/infrastructureName","Value":"rosa-abc123"},{"Key":"velero.io/backup-location","Value":"default"}]}
EOF
  run get_velero_bucket_infra_id "ro" "managed-velero-backups-abc"
  [ "$status" -eq 0 ]
  [ "$output" = "rosa-abc123" ]
}

@test "route53_zone_exists_for_infra: returns 0 when zone found" {
  cat > "${MOCK_AWS_RESPONSES}/route53_list-hosted-zones_--profile_ro_--output_json.json" <<'EOF'
{"HostedZones":[{"Name":"rosa-abc123.example.com.","Id":"/hostedzone/Z123"}]}
EOF
  run route53_zone_exists_for_infra "ro" "rosa-abc123"
  [ "$status" -eq 0 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
bats tests/lib/test_aws.bats
```

- [ ] **Step 3: Implement `scripts/lib/aws.sh`**

```bash
#!/usr/bin/env bash
# AWS query functions for clusterpool-cleanup skills.

# List all AWS regions.
# Usage: get_aws_regions <profile>
# Prints one region name per line.
get_aws_regions() {
  local profile="$1"
  aws ec2 describe-regions --profile "$profile" --output json 2>/dev/null \
    | python3 -c "import sys,json; [print(r['RegionName']) for r in json.load(sys.stdin)['Regions']]"
}

# Get all kubernetes.io/cluster/* tag keys in a region.
# Usage: get_cluster_tag_keys <profile> <region>
# Prints infra IDs (the part after kubernetes.io/cluster/) one per line.
get_cluster_tag_keys() {
  local profile="$1"
  local region="$2"
  aws resourcegroupstaggingapi get-tag-keys \
    --region "$region" --profile "$profile" --output json 2>/dev/null \
    | python3 -c "
import sys, json
keys = json.load(sys.stdin).get('TagKeys', [])
for k in keys:
    if k.startswith('kubernetes.io/cluster/'):
        print(k.replace('kubernetes.io/cluster/', ''))
"
}

# Check if an infra ID still has tagged AWS resources in a region.
# Usage: infra_id_has_ec2_resources <profile> <region> <infra_id>
# Returns: 0 if resources found, 1 if not
infra_id_has_ec2_resources() {
  local profile="$1"
  local region="$2"
  local infra_id="$3"
  local count
  count=$(aws resourcegroupstaggingapi get-resources \
    --region "$region" --profile "$profile" \
    --tag-filters "Key=kubernetes.io/cluster/${infra_id},Values=owned" \
    --output json 2>/dev/null \
    | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('ResourceTagMappingList', [])))")
  [[ "$count" -gt 0 ]]
}

# Get all tagged resource ARNs for an infra ID in a region.
# Usage: get_infra_resources <profile> <region> <infra_id>
# Prints JSON array of resource ARNs.
get_infra_resources() {
  local profile="$1"
  local region="$2"
  local infra_id="$3"
  aws resourcegroupstaggingapi get-resources \
    --region "$region" --profile "$profile" \
    --tag-filters "Key=kubernetes.io/cluster/${infra_id},Values=owned" \
    --output json 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
arns = [r['ResourceARN'] for r in data.get('ResourceTagMappingList', [])]
print(json.dumps(arns))
"
}

# List all S3 buckets matching a name prefix.
# Usage: list_s3_buckets_matching <profile> <prefix>
# Prints one bucket name per line.
list_s3_buckets_matching() {
  local profile="$1"
  local prefix="$2"
  aws s3 ls --profile "$profile" 2>/dev/null \
    | awk '{print $3}' \
    | grep "^${prefix}"
}

# Get the velero.io/infrastructureName tag from a bucket.
# Usage: get_velero_bucket_infra_id <profile> <bucket>
# Prints infra ID to stdout, or empty string if not found.
get_velero_bucket_infra_id() {
  local profile="$1"
  local bucket="$2"
  aws s3api get-bucket-tagging --bucket "$bucket" --profile "$profile" 2>/dev/null \
    | python3 -c "
import sys, json
try:
    tags = {t['Key']: t['Value'] for t in json.load(sys.stdin).get('TagSet', [])}
    print(tags.get('velero.io/infrastructureName', ''))
except:
    print('')
"
}

# Get bucket creation date.
# Usage: get_bucket_creation_date <profile> <bucket>
get_bucket_creation_date() {
  local profile="$1"
  local bucket="$2"
  aws s3 ls --profile "$profile" 2>/dev/null \
    | awk -v b="$bucket" '$3 == b {print $1}'
}

# Check if a Route53 hosted zone exists for an infra ID.
# Usage: route53_zone_exists_for_infra <profile> <infra_id>
# Returns: 0 if zone found, 1 if not
route53_zone_exists_for_infra() {
  local profile="$1"
  local infra_id="$2"
  aws route53 list-hosted-zones --profile "$profile" --output json 2>/dev/null \
    | python3 -c "
import sys, json
zones = json.load(sys.stdin).get('HostedZones', [])
found = any('${infra_id}' in z.get('Name', '') for z in zones)
exit(0 if found else 1)
"
}

# Get all S3 buckets with their tags (for non-managed-velero-backups buckets).
# Usage: list_all_s3_buckets <profile>
# Prints JSON array of {name, created, tags} objects.
list_all_s3_buckets() {
  local profile="$1"
  aws s3 ls --profile "$profile" 2>/dev/null \
    | awk '{print $3}' \
    | python3 -c "
import sys, subprocess, json
buckets = []
for line in sys.stdin:
    name = line.strip()
    if not name:
        continue
    buckets.append({'name': name})
print(json.dumps(buckets))
"
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
bats tests/lib/test_aws.bats
```

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/aws.sh tests/lib/test_aws.bats tests/fixtures/
git commit -m "feat: add AWS query library with tests"
```

---

### Task 5: Manifest library (`scripts/lib/manifest.sh`)

**Files:**
- Create: `scripts/lib/manifest.sh`
- Create: `tests/lib/test_manifest.bats`

- [ ] **Step 1: Write failing tests**

`tests/lib/test_manifest.bats`:
```bash
#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../../scripts/lib/manifest.sh"
  export TEST_MANIFEST=$(mktemp)
}

teardown() {
  rm -f "$TEST_MANIFEST"
}

@test "manifest_init: creates valid JSON manifest" {
  run manifest_init "$TEST_MANIFEST"
  [ "$status" -eq 0 ]
  run python3 -c "import json; json.load(open('${TEST_MANIFEST}'))"
  [ "$status" -eq 0 ]
}

@test "manifest_set_cc_resource_cleanup_run: sets flag to true" {
  manifest_init "$TEST_MANIFEST"
  run manifest_set_cc_resource_cleanup_run "$TEST_MANIFEST" true
  [ "$status" -eq 0 ]
  local val
  val=$(python3 -c "import json; print(json.load(open('${TEST_MANIFEST}'))['cc_resource_cleanup_run'])")
  [ "$val" = "True" ]
}

@test "manifest_get_cc_resource_cleanup_run: returns false for new manifest" {
  manifest_init "$TEST_MANIFEST"
  run manifest_get_cc_resource_cleanup_run "$TEST_MANIFEST"
  [ "$status" -eq 0 ]
  [ "$output" = "false" ]
}

@test "manifest_add_item: appends item to items array" {
  manifest_init "$TEST_MANIFEST"
  local item='{"resource":"test-bucket","type":"s3","confidence":"HIGH"}'
  run manifest_add_item "$TEST_MANIFEST" "$item"
  [ "$status" -eq 0 ]
  local count
  count=$(python3 -c "import json; print(len(json.load(open('${TEST_MANIFEST}'))['items']))")
  [ "$count" -eq 1 ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
bats tests/lib/test_manifest.bats
```

- [ ] **Step 3: Implement `scripts/lib/manifest.sh`**

```bash
#!/usr/bin/env bash
# Manifest read/write functions for clusterpool-cleanup skills.
# Manifest format: JSON with items array and metadata fields.

MANIFEST_DEFAULT_PATH="/tmp/clusterpool-cleanup-manifest.json"

# Initialize a new manifest file.
# Usage: manifest_init <path>
manifest_init() {
  local path="${1:-$MANIFEST_DEFAULT_PATH}"
  python3 -c "
import json
manifest = {
    'version': '1',
    'created_at': __import__('datetime').datetime.utcnow().isoformat() + 'Z',
    'cc_resource_cleanup_run': False,
    'items': []
}
with open('${path}', 'w') as f:
    json.dump(manifest, f, indent=2)
"
}

# Set cc_resource_cleanup_run flag.
# Usage: manifest_set_cc_resource_cleanup_run <path> <true|false>
manifest_set_cc_resource_cleanup_run() {
  local path="$1"
  local value="$2"
  python3 -c "
import json
with open('${path}') as f:
    m = json.load(f)
m['cc_resource_cleanup_run'] = '${value}' == 'true'
with open('${path}', 'w') as f:
    json.dump(m, f, indent=2)
"
}

# Get cc_resource_cleanup_run value.
# Usage: manifest_get_cc_resource_cleanup_run <path>
# Prints true or false.
manifest_get_cc_resource_cleanup_run() {
  local path="${1:-$MANIFEST_DEFAULT_PATH}"
  if [[ ! -f "$path" ]]; then
    echo "false"
    return 0
  fi
  python3 -c "
import json
try:
    with open('${path}') as f:
        m = json.load(f)
    print('true' if m.get('cc_resource_cleanup_run') else 'false')
except:
    print('false')
"
}

# Add an item to the manifest.
# Usage: manifest_add_item <path> <item-json>
# Item JSON shape: {resource, type, origin, created, why_orphaned, confidence, action, region?, infra_id?}
manifest_add_item() {
  local path="$1"
  local item="$2"
  python3 - "$path" "$item" <<'PYEOF'
import json, sys
path = sys.argv[1]
item = json.loads(sys.argv[2])
with open(path) as f:
    m = json.load(f)
m['items'].append(item)
with open(path, 'w') as f:
    json.dump(m, f, indent=2)
PYEOF
}

# Read all items from manifest.
# Usage: manifest_get_items <path>
# Prints JSON array.
manifest_get_items() {
  local path="${1:-$MANIFEST_DEFAULT_PATH}"
  python3 -c "
import json
with open('${path}') as f:
    m = json.load(f)
print(json.dumps(m.get('items', [])))
"
}

# CLI dispatch — allows calling functions directly:
#   bash manifest.sh manifest_init /tmp/foo.json
#   bash manifest.sh manifest_add_item /tmp/foo.json '<json>'
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  "$@"
fi
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
bats tests/lib/test_manifest.bats
```

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/manifest.sh tests/lib/test_manifest.bats
git commit -m "feat: add manifest library with tests"
```

---

## Phase 2: Cleanup Skills

### Task 6: CD scan script (`scripts/scan-cds.sh`)

**Files:**
- Create: `scripts/scan-cds.sh`
- Create: `tests/test_scan_cds.bats`

- [ ] **Step 1: Write failing tests**

`tests/test_scan_cds.bats`:
```bash
#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/collective.sh"
  source "${BATS_TEST_DIRNAME}/helpers/mock_kubectl.sh"
  export MOCK_KUBECTL_RESPONSES="${BATS_TEST_DIRNAME}/fixtures/kubectl"
  mkdir -p "$MOCK_KUBECTL_RESPONSES"
}

@test "scan-cds: outputs JSON with deprovision_failed and stuck_provisioning arrays" {
  local old_time
  old_time=$(date -u -v-25H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u --date='25 hours ago' '+%Y-%m-%dT%H:%M:%SZ')
  cat > "${MOCK_KUBECTL_RESPONSES}/get_clusterdeployment_--all-namespaces_-l_cluster.open-cluster-management.io_clusterset=app_-o_json.json" <<EOF
{"items":[
  {"metadata":{"name":"cd-dead","namespace":"cd-dead","creationTimestamp":"${old_time}"},
   "spec":{"clusterMetadata":{"infraID":"dead-infra"}},
   "status":{"provisionStatus":"DeprovisionFailed"}},
  {"metadata":{"name":"stuck-cd","namespace":"stuck-cd","creationTimestamp":"${old_time}"},
   "status":{"provisionStatus":"Provisioning"}}
]}
EOF
  run bash "${BATS_TEST_DIRNAME}/../scripts/scan-cds.sh" --namespace app
  [ "$status" -eq 0 ]
  [[ "$output" == *"deprovision_failed"* ]]
  [[ "$output" == *"stuck_provisioning"* ]]
  [[ "$output" == *"cd-dead"* ]]
  [[ "$output" == *"stuck-cd"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bats tests/test_scan_cds.bats
```

- [ ] **Step 3: Implement `scripts/scan-cds.sh`**

```bash
#!/usr/bin/env bash
# Scan collective cluster for stuck ClusterDeployments.
# Outputs JSON: {deprovision_failed: [...], stuck_provisioning: [...]}

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/collective.sh"

NAMESPACE="app"
STUCK_THRESHOLD_HOURS=24

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --threshold-hours) STUCK_THRESHOLD_HOURS="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

deprovision_failed=$(get_deprovision_failed_cds "$NAMESPACE")
stuck_provisioning=$(get_stuck_provisioning_cds "$NAMESPACE" "$STUCK_THRESHOLD_HOURS")

python3 -c "
import json
print(json.dumps({
    'deprovision_failed': json.loads('${deprovision_failed}'),
    'stuck_provisioning': json.loads('${stuck_provisioning}')
}, indent=2))
"
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bats tests/test_scan_cds.bats
```

- [ ] **Step 5: Commit**

```bash
git add scripts/scan-cds.sh tests/test_scan_cds.bats
git commit -m "feat: add CD scan script with tests"
```

---

### Task 7: CC resource scan script (`scripts/scan-cc-resources.sh`)

**Files:**
- Create: `scripts/scan-cc-resources.sh`
- Create: `tests/test_scan_cc_resources.bats`

- [ ] **Step 1: Write failing tests**

`tests/test_scan_cc_resources.bats`:
```bash
#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/aws.sh"
  source "${BATS_TEST_DIRNAME}/../scripts/lib/collective.sh"
  source "${BATS_TEST_DIRNAME}/helpers/mock_aws.sh"
  source "${BATS_TEST_DIRNAME}/helpers/mock_kubectl.sh"
  export MOCK_AWS_RESPONSES="${BATS_TEST_DIRNAME}/fixtures/aws"
  export MOCK_KUBECTL_RESPONSES="${BATS_TEST_DIRNAME}/fixtures/kubectl"
  mkdir -p "$MOCK_AWS_RESPONSES" "$MOCK_KUBECTL_RESPONSES"
}

@test "scan-cc-resources: flags infra IDs with no live CD as orphaned" {
  # Region list
  cat > "${MOCK_AWS_RESPONSES}/ec2_describe-regions_--profile_rw_--output_json.json" <<'EOF'
{"Regions":[{"RegionName":"us-east-1"}]}
EOF
  # Tag keys in us-east-1 — one orphaned infra, one live
  cat > "${MOCK_AWS_RESPONSES}/resourcegroupstaggingapi_get-tag-keys_--region_us-east-1_--profile_rw_--output_json.json" <<'EOF'
{"TagKeys":["kubernetes.io/cluster/orphan-infra","kubernetes.io/cluster/live-infra"]}
EOF
  # Resources for orphaned infra
  cat > "${MOCK_AWS_RESPONSES}/resourcegroupstaggingapi_get-resources_--region_us-east-1_--profile_rw_--tag-filters_Key_kubernetes.io_cluster_orphan-infra_Values_owned_--output_json.json" <<'EOF'
{"ResourceTagMappingList":[{"ResourceARN":"arn:aws:ec2:us-east-1:999:vpc/vpc-abc"}]}
EOF
  # Live CDs on collective — only live-infra is active
  cat > "${MOCK_KUBECTL_RESPONSES}/get_clusterdeployment_--all-namespaces_-l_cluster.open-cluster-management.io_clusterset=app_-o_json.json" <<'EOF'
{"items":[{"spec":{"clusterMetadata":{"infraID":"live-infra"}},"status":{"provisionStatus":"Provisioned"}}]}
EOF

  run bash "${BATS_TEST_DIRNAME}/../scripts/scan-cc-resources.sh" \
    --profile rw --namespace app
  [ "$status" -eq 0 ]
  [[ "$output" == *"orphan-infra"* ]]
  [[ "$output" != *"live-infra"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
bats tests/test_scan_cc_resources.bats
```

- [ ] **Step 3: Implement `scripts/scan-cc-resources.sh`**

```bash
#!/usr/bin/env bash
# Scan AWS for tagged resource groups from collective ClusterDeployments with no live CD.
# Outputs JSON array of orphaned resource groups with region, infra_id, resource_count, resources.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/aws.sh"
source "${SCRIPT_DIR}/lib/collective.sh"

PROFILE=""
NAMESPACE="app"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$PROFILE" ]] && { echo "ERROR: --profile required" >&2; exit 1; }

# Get live infra IDs from collective
live_infra_ids=$(get_live_infra_ids "$NAMESPACE")

TMPFILE=$(mktemp)
echo "[]" > "$TMPFILE"

while IFS= read -r region; do
  while IFS= read -r infra_id; do
    [[ -z "$infra_id" ]] && continue
    # Skip if this infra ID belongs to a live CD
    if echo "$live_infra_ids" | grep -qxF "$infra_id"; then
      continue
    fi
    # Get resources for this infra ID
    resources=$(get_infra_resources "$PROFILE" "$region" "$infra_id")
    count=$(echo "$resources" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
    if [[ "$count" -gt 0 ]]; then
      python3 - "$TMPFILE" "$infra_id" "$region" "$count" <<PYEOF
import json, sys
path, infra_id, region, count = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
with open(path) as f:
    items = json.load(f)
items.append({"infra_id": infra_id, "region": region, "resource_count": count})
with open(path, "w") as f:
    json.dump(items, f, indent=2)
PYEOF
    fi
  done < <(get_cluster_tag_keys "$PROFILE" "$region")
done < <(get_aws_regions "$PROFILE")

cat "$TMPFILE"
rm -f "$TMPFILE"
```

- [ ] **Step 4: Run test to verify it passes**

```bash
bats tests/test_scan_cc_resources.bats
```

- [ ] **Step 5: Commit**

```bash
git add scripts/scan-cc-resources.sh tests/test_scan_cc_resources.bats
git commit -m "feat: add CC resource scan script with tests"
```

---

### Task 8: `cd-cleanup` skill

**Files:**
- Create: `skills/clusterpool-cleanup/cd-cleanup.md`

This is a Claude Code skill — no unit tests. Verify by invoking in Claude Code.

- [ ] **Step 1: Create skill file**

`skills/clusterpool-cleanup/cd-cleanup.md`:
```markdown
---
name: clusterpool-cleanup:cd-cleanup
description: Clean up stuck ClusterDeployment objects on the collective cluster (DeprovisionFailed and stuck Provisioning). Requires collective cluster write access via kubectl. No AWS credentials needed.
---

# cd-cleanup

Clean up stuck ClusterDeployment objects on the collective cluster.

## Pre-flight

1. Ask: "Collective cluster namespace? (default: app):" — store as NAMESPACE
2. Run: `kubectl get clusterpool -n <NAMESPACE>`
   - If it fails: "Please log in first: oc login <api-url from kubectl config view>" — STOP

## Scan

Run: `bash <repo>/scripts/scan-cds.sh --namespace <NAMESPACE>`

Parse the JSON output:
- `deprovision_failed[]` — CDs needing finalizer removal
- `stuck_provisioning[]` — CDs needing deletion

## Present cleanup plan

Group items by type. Use the expand/select/deselect UI:

```
=== cd-cleanup Plan ===

[MEDIUM CONFIDENCE]
 [1] ✓  N DeprovisionFailed ClusterDeployments (finalizer removal)
 [2] ✓  N Provisioning CDs stuck >24h (deletion)

Commands: <number> to toggle group, e<number> to expand, <number><letter> to toggle item, Enter to proceed
```

For each item when expanded show:
- CD name and namespace
- Current state and reason
- Age

Wait for user input. Toggle selections as requested. When user presses Enter:

## Confirm

"Proceed with selected items? (y/n)"
If n: STOP.

## Execute

For each selected item, immediately before acting:
- Re-query: `kubectl get clusterdeployment -n <namespace> <name> -o jsonpath='{.status.provisionStatus}'`
- If state has changed: skip, note as "Skipped (state changed)"

For DeprovisionFailed CDs: remove finalizers
`kubectl patch clusterdeployment -n <namespace> <name> -p '{"metadata":{"finalizers":[]}}' --type=merge`

For stuck Provisioning CDs: delete
`kubectl delete clusterdeployment -n <namespace> <name>`

## Summary

```
cd-cleanup summary:
  Finalizers removed:      N
  CDs deleted:             N
  Skipped (state changed): N
  Failed:                  N
```
```

- [ ] **Step 2: Register skill with superpowers**

Use the `superpowers:writing-skills` skill to register `cd-cleanup.md`. That skill handles
locating the correct plugin directory and verifying the skill loads.

As a fallback, symlink the skills directory into the superpowers plugin cache:
```bash
PLUGIN_DIR=$(ls -d ~/.claude/plugins/cache/claude-plugins-official/superpowers/*/skills 2>/dev/null | tail -1)
ln -sf "$(pwd)/skills/clusterpool-cleanup" "${PLUGIN_DIR}/clusterpool-cleanup"
```
Verify the skill is recognized:
```bash
# In a Claude Code session, run:
# /clusterpool-cleanup:cd-cleanup
# Expected: skill loads and shows pre-flight prompt
```

- [ ] **Step 3: Test skill manually in Claude Code**

Invoke: `/cd-cleanup` (or via Skill tool)
Verify:
- Pre-flight prompts appear
- Scan runs and shows results
- Expand/collapse works
- Confirm prompt appears before any action
- Summary appears after

- [ ] **Step 4: Commit**

```bash
git add skills/clusterpool-cleanup/cd-cleanup.md
git commit -m "feat: add cd-cleanup Claude skill"
```

---

### Task 9: `cc-resource-cleanup` skill

**Files:**
- Create: `skills/clusterpool-cleanup/cc-resource-cleanup.md`

- [ ] **Step 1: Create skill file**

`skills/clusterpool-cleanup/cc-resource-cleanup.md`:
```markdown
---
name: clusterpool-cleanup:cc-resource-cleanup
description: Clean up orphaned AWS resources left behind by cluster claims on the collective, using hiveutil aws-tag-deprovision. Requires collective cluster read access and AWS write credentials.
---

# cc-resource-cleanup

Clean up orphaned AWS resources left behind by cluster claims on the collective.

## Pre-flight

1. Ask: "Collective cluster namespace? (default: app):" — store as NAMESPACE
2. Run: `kubectl get clusterpool -n <NAMESPACE>`
   - If fails: "Please log in first: oc login <api-url>" — STOP
3. Ask: "hiveutil path? (default: ~/DEV/openshift/hive/bin/hiveutil):" — store as HIVEUTIL
   - Verify: `[[ -x "$HIVEUTIL" ]]` — if not: STOP with error

## hiveutil update check

```bash
cd <hiveutil-repo-dir>
git fetch origin main --quiet
git_status=$(git status)
```
If output contains "branch is behind":
  Ask: "hiveutil is out of date. Update before continuing? (y/n)"
  If y: `git pull && make build-hiveutil`

## Scan

Ask: "AWS write profile? (default: aws-acm-dev11):" — store as WRITE_PROFILE

Run: `bash <repo>/scripts/scan-cc-resources.sh --profile <WRITE_PROFILE> --namespace <NAMESPACE>`

## Present cleanup plan

```
=== cc-resource-cleanup Plan ===

[HIGH CONFIDENCE]
 [1] ✓  N orphaned resource groups from collective ClusterDeployments

Commands: <number> to toggle group, e<number> to expand, <number><letter> to toggle item, Enter to proceed
```

When expanded, show per infra ID:
- Infra ID
- Region
- Resource count and types
- Why orphaned: "No active ClusterDeployment found for this infra ID"

## Verify credentials (immediately before first deletion)

Run: `aws sts get-caller-identity --profile <WRITE_PROFILE>`
If this fails: "ERROR: AWS credentials invalid for profile '<WRITE_PROFILE>'. Cannot proceed." — STOP.

## Confirm

"Proceed with selected items? (y/n)"
If n: STOP.

## Execute

For each selected infra ID, immediately before running hiveutil:
- Re-check: `kubectl get clusterdeployment --all-namespaces -l cluster.open-cluster-management.io/clusterset=<NAMESPACE> -o jsonpath='{.items[*].spec.clusterMetadata.infraID}'`
- If infra ID now appears in live CDs: skip, note as "Skipped (state changed)"

Run: `<HIVEUTIL> aws-tag-deprovision kubernetes.io/cluster/<infra_id>=owned --region <region> --loglevel info`

Note result (success/failure) per item.

After all items: update manifest if it exists at /tmp/clusterpool-cleanup-manifest.json:
Set `cc_resource_cleanup_run: true` using `scripts/lib/manifest.sh`

## Summary

```
cc-resource-cleanup summary:
  Resource groups cleaned: N (via hiveutil)
  Skipped (state changed): N
  Failed:                  N
```
```

- [ ] **Step 2: Register and test manually in Claude Code**

The symlink created in Task 8 Step 2 covers the whole `skills/clusterpool-cleanup/` directory —
no additional registration needed. Invoke and verify pre-flight, hiveutil update check, scan, UI, confirm, summary.

- [ ] **Step 3: Commit**

```bash
git add skills/clusterpool-cleanup/cc-resource-cleanup.md
git commit -m "feat: add cc-resource-cleanup Claude skill"
```

---

## Phase 3: Orphan Skills

### Task 10: Orphan scan script (`scripts/scan-orphans.sh`)

**Files:**
- Create: `scripts/scan-orphans.sh`
- Create: `tests/test_scan_orphans.bats`

- [ ] **Step 1: Write failing tests**

`tests/test_scan_orphans.bats`:
```bash
#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../scripts/lib/aws.sh"
  source "${BATS_TEST_DIRNAME}/../scripts/lib/collective.sh"
  source "${BATS_TEST_DIRNAME}/helpers/mock_aws.sh"
  source "${BATS_TEST_DIRNAME}/helpers/mock_kubectl.sh"
  export MOCK_AWS_RESPONSES="${BATS_TEST_DIRNAME}/fixtures/aws"
  export MOCK_KUBECTL_RESPONSES="${BATS_TEST_DIRNAME}/fixtures/kubectl"
  mkdir -p "$MOCK_AWS_RESPONSES" "$MOCK_KUBECTL_RESPONSES"
}

@test "scan-orphans: detects orphaned managed-velero-backups ROSA bucket" {
  # S3 bucket list
  cat > "${MOCK_AWS_RESPONSES}/s3_ls_--profile_ro.txt" <<'EOF'
2026-02-14 managed-velero-backups-abc-uuid
EOF
  # Bucket tags — ROSA infra
  cat > "${MOCK_AWS_RESPONSES}/s3api_get-bucket-tagging_--bucket_managed-velero-backups-abc-uuid_--profile_ro.json" <<'EOF'
{"TagSet":[{"Key":"velero.io/infrastructureName","Value":"rosa-abc123"}]}
EOF
  # No EC2 resources for that infra ID in any region
  cat > "${MOCK_AWS_RESPONSES}/ec2_describe-regions_--profile_ro_--output_json.json" <<'EOF'
{"Regions":[{"RegionName":"us-east-1"}]}
EOF
  cat > "${MOCK_AWS_RESPONSES}/resourcegroupstaggingapi_get-tag-keys_--region_us-east-1_--profile_ro_--output_json.json" <<'EOF'
{"TagKeys":[]}
EOF
  # No Route53 zone
  cat > "${MOCK_AWS_RESPONSES}/route53_list-hosted-zones_--profile_ro_--output_json.json" <<'EOF'
{"HostedZones":[]}
EOF
  # No live CDs
  cat > "${MOCK_KUBECTL_RESPONSES}/get_clusterdeployment_--all-namespaces_-l_cluster.open-cluster-management.io_clusterset=app_-o_json.json" <<'EOF'
{"items":[]}
EOF

  run bash "${BATS_TEST_DIRNAME}/../scripts/scan-orphans.sh" \
    --profile ro --namespace app
  [ "$status" -eq 0 ]
  [[ "$output" == *"managed-velero-backups-abc-uuid"* ]]
  [[ "$output" == *"rosa-abc123"* ]]
  [[ "$output" == *"HIGH"* ]]
}

@test "scan-orphans: detects orphaned IAM role matching cluster pattern with no live CD" {
  cat > "${MOCK_AWS_RESPONSES}/ec2_describe-regions_--profile_ro_--output_json.json" <<'EOF'
{"Regions":[{"RegionName":"us-east-1"}]}
EOF
  cat > "${MOCK_AWS_RESPONSES}/resourcegroupstaggingapi_get-tag-keys_--region_us-east-1_--profile_ro_--output_json.json" <<'EOF'
{"TagKeys":[]}
EOF
  cat > "${MOCK_AWS_RESPONSES}/route53_list-hosted-zones_--profile_ro_--output_json.json" <<'EOF'
{"HostedZones":[]}
EOF
  cat > "${MOCK_AWS_RESPONSES}/iam_list-roles_--profile_ro_--output_json.json" <<'EOF'
{"Roles":[{"RoleName":"app-prow-dead-abc-worker-role"}]}
EOF
  cat > "${MOCK_AWS_RESPONSES}/iam_list-instance-profiles_--profile_ro_--output_json.json" <<'EOF'
{"InstanceProfiles":[]}
EOF
  # Empty S3 listing — required to prevent mock error from aborting scan
  cat > "${MOCK_AWS_RESPONSES}/s3_ls_--profile_ro.json" <<'EOF'
EOF
  cat > "${MOCK_KUBECTL_RESPONSES}/get_clusterdeployment_--all-namespaces_-l_cluster.open-cluster-management.io_clusterset=app_-o_json.json" <<'EOF'
{"items":[]}
EOF
  echo '{"items":[]}' > "${MOCK_KUBECTL_RESPONSES}/get_clusterpool_-n_app_-o_json.json"

  run bash "${BATS_TEST_DIRNAME}/../scripts/scan-orphans.sh" \
    --profile ro --namespace app
  [ "$status" -eq 0 ]
  [[ "$output" == *"app-prow-dead-abc-worker-role"* ]]
  [[ "$output" == *"iam_role"* ]]
}

@test "scan-orphans: does NOT flag IAM role whose infra ID matches a live CD" {
  cat > "${MOCK_AWS_RESPONSES}/ec2_describe-regions_--profile_ro_--output_json.json" <<'EOF'
{"Regions":[{"RegionName":"us-east-1"}]}
EOF
  cat > "${MOCK_AWS_RESPONSES}/resourcegroupstaggingapi_get-tag-keys_--region_us-east-1_--profile_ro_--output_json.json" <<'EOF'
{"TagKeys":[]}
EOF
  cat > "${MOCK_AWS_RESPONSES}/route53_list-hosted-zones_--profile_ro_--output_json.json" <<'EOF'
{"HostedZones":[]}
EOF
  # Role name contains live infra ID
  cat > "${MOCK_AWS_RESPONSES}/iam_list-roles_--profile_ro_--output_json.json" <<'EOF'
{"Roles":[{"RoleName":"app-prow-live-abc-worker-role"}]}
EOF
  cat > "${MOCK_AWS_RESPONSES}/iam_list-instance-profiles_--profile_ro_--output_json.json" <<'EOF'
{"InstanceProfiles":[]}
EOF
  cat > "${MOCK_AWS_RESPONSES}/s3_ls_--profile_ro.json" <<'EOF'
EOF
  # Live CD with infra ID that appears in the role name
  cat > "${MOCK_KUBECTL_RESPONSES}/get_clusterdeployment_--all-namespaces_-l_cluster.open-cluster-management.io_clusterset=app_-o_json.json" <<'EOF'
{"items":[{"spec":{"clusterMetadata":{"infraID":"app-prow-live-abc"}},"status":{"provisionStatus":"Provisioned"}}]}
EOF
  echo '{"items":[]}' > "${MOCK_KUBECTL_RESPONSES}/get_clusterpool_-n_app_-o_json.json"

  run bash "${BATS_TEST_DIRNAME}/../scripts/scan-orphans.sh" \
    --profile ro --namespace app
  [ "$status" -eq 0 ]
  [[ "$output" != *"app-prow-live-abc-worker-role"* ]]
}

@test "scan-orphans: detects DeprovisionFailed CD when collective is reachable" {
  local old_time
  old_time=$(date -u -v-25H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u --date='25 hours ago' '+%Y-%m-%dT%H:%M:%SZ')
  cat > "${MOCK_AWS_RESPONSES}/ec2_describe-regions_--profile_ro_--output_json.json" <<'EOF'
{"Regions":[{"RegionName":"us-east-1"}]}
EOF
  cat > "${MOCK_AWS_RESPONSES}/resourcegroupstaggingapi_get-tag-keys_--region_us-east-1_--profile_ro_--output_json.json" <<'EOF'
{"TagKeys":[]}
EOF
  cat > "${MOCK_AWS_RESPONSES}/route53_list-hosted-zones_--profile_ro_--output_json.json" <<'EOF'
{"HostedZones":[]}
EOF
  cat > "${MOCK_AWS_RESPONSES}/iam_list-roles_--profile_ro_--output_json.json" <<'EOF'
{"Roles":[]}
EOF
  cat > "${MOCK_AWS_RESPONSES}/iam_list-instance-profiles_--profile_ro_--output_json.json" <<'EOF'
{"InstanceProfiles":[]}
EOF
  cat > "${MOCK_AWS_RESPONSES}/s3_ls_--profile_ro.json" <<'EOF'
EOF
  cat > "${MOCK_KUBECTL_RESPONSES}/get_clusterdeployment_--all-namespaces_-l_cluster.open-cluster-management.io_clusterset=app_-o_json.json" <<EOF
{"items":[
  {"metadata":{"name":"dead-cd","namespace":"dead-cd","creationTimestamp":"${old_time}"},
   "spec":{"clusterMetadata":{"infraID":"dead-infra"}},
   "status":{"provisionStatus":"DeprovisionFailed"}}
]}
EOF
  # clusterpool check (for verify_collective_access)
  echo '{"items":[]}' > "${MOCK_KUBECTL_RESPONSES}/get_clusterpool_-n_app_-o_json.json"

  run bash "${BATS_TEST_DIRNAME}/../scripts/scan-orphans.sh" \
    --profile ro --namespace app
  [ "$status" -eq 0 ]
  [[ "$output" == *"dead-cd"* ]]
  [[ "$output" == *"cd_deprovision_failed"* ]]
}

@test "scan-orphans: does not flag managed-velero-backups bucket whose ROSA cluster still exists" {
  cat > "${MOCK_AWS_RESPONSES}/s3_ls_--profile_ro.txt" <<'EOF'
2026-02-14 managed-velero-backups-live-uuid
EOF
  cat > "${MOCK_AWS_RESPONSES}/s3api_get-bucket-tagging_--bucket_managed-velero-backups-live-uuid_--profile_ro.json" <<'EOF'
{"TagSet":[{"Key":"velero.io/infrastructureName","Value":"rosa-live123"}]}
EOF
  cat > "${MOCK_AWS_RESPONSES}/ec2_describe-regions_--profile_ro_--output_json.json" <<'EOF'
{"Regions":[{"RegionName":"us-east-1"}]}
EOF
  # EC2 resources exist for live infra → cluster is still running
  cat > "${MOCK_AWS_RESPONSES}/resourcegroupstaggingapi_get-tag-keys_--region_us-east-1_--profile_ro_--output_json.json" <<'EOF'
{"TagKeys":["kubernetes.io/cluster/rosa-live123"]}
EOF
  cat > "${MOCK_AWS_RESPONSES}/resourcegroupstaggingapi_get-resources_--region_us-east-1_--profile_ro_--tag-filters_Key_kubernetes.io_cluster_rosa-live123_Values_owned_--output_json.json" <<'EOF'
{"ResourceTagMappingList":[{"ResourceARN":"arn:aws:ec2:us-east-1:999:instance/i-abc"}]}
EOF
  cat > "${MOCK_KUBECTL_RESPONSES}/get_clusterdeployment_--all-namespaces_-l_cluster.open-cluster-management.io_clusterset=app_-o_json.json" <<'EOF'
{"items":[]}
EOF

  run bash "${BATS_TEST_DIRNAME}/../scripts/scan-orphans.sh" \
    --profile ro --namespace app
  [ "$status" -eq 0 ]
  [[ "$output" != *"managed-velero-backups-live-uuid"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
bats tests/test_scan_orphans.bats
```

- [ ] **Step 3: Implement `scripts/scan-orphans.sh`**

```bash
#!/usr/bin/env bash
# Full orphan scan across all resource types in the shared AWS account.
# Outputs JSON array of orphaned items with confidence, origin, and recommended action.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/aws.sh"
source "${SCRIPT_DIR}/lib/collective.sh"

PROFILE=""
NAMESPACE="app"
STUCK_THRESHOLD_HOURS=24

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --threshold-hours) STUCK_THRESHOLD_HOURS="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -z "$PROFILE" ]] && { echo "ERROR: --profile required" >&2; exit 1; }

TMPFILE=$(mktemp)
echo "[]" > "$TMPFILE"

# Helper: append a JSON item object to the temp file.
append_item() {
  local item_json="$1"
  python3 - "$TMPFILE" "$item_json" <<'PYEOF'
import json, sys
path = sys.argv[1]
item = json.loads(sys.argv[2])
with open(path) as f:
    items = json.load(f)
items.append(item)
with open(path, "w") as f:
    json.dump(items, f, indent=2)
PYEOF
}

# ── Get live infra IDs from collective (best effort) ──────────────────────────
live_infra_ids=""
collective_reachable=false
if kubectl get clusterpool -n "$NAMESPACE" &>/dev/null; then
  collective_reachable=true
  live_infra_ids=$(get_live_infra_ids "$NAMESPACE" 2>/dev/null || echo "")
fi

# ── Get all AWS regions ───────────────────────────────────────────────────────
regions=$(get_aws_regions "$PROFILE")

# ── Scan Collective ClusterDeployments (if collective reachable) ──────────────
if [[ "$collective_reachable" == "true" ]]; then
  cd_json=$(bash "${SCRIPT_DIR}/scan-cds.sh" --namespace "$NAMESPACE" --threshold-hours "$STUCK_THRESHOLD_HOURS" || echo '{"deprovision_failed":[],"stuck_provisioning":[]}')
  python3 - "$TMPFILE" "$cd_json" "$STUCK_THRESHOLD_HOURS" <<'PYEOF'
import json, sys
path = sys.argv[1]
cd_data = json.loads(sys.argv[2])
threshold_hours = sys.argv[3]
with open(path) as f:
    items = json.load(f)
for cd in cd_data.get("deprovision_failed", []):
    items.append({
        "resource": cd["name"],
        "type": "cd_deprovision_failed",
        "namespace": cd["namespace"],
        "infra_id": cd.get("infraID", ""),
        "origin": "Collective ClusterDeployment — DeprovisionFailed (AWS credentials expired)",
        "why_orphaned": "Hive cannot deprovision; AWS credentials have expired or been rotated",
        "confidence": "MEDIUM",
        "action": "cd_remove_finalizer",
    })
for cd in cd_data.get("stuck_provisioning", []):
    items.append({
        "resource": cd["name"],
        "type": "cd_stuck_provisioning",
        "namespace": cd["namespace"],
        "origin": f"Collective ClusterDeployment — stuck in Provisioning >{threshold_hours}h",
        "why_orphaned": "Provisioning has not completed within the expected time window",
        "confidence": "MEDIUM",
        "action": "cd_delete",
    })
with open(path, "w") as f:
    json.dump(items, f, indent=2)
PYEOF
fi

# ── Scan tagged AWS resources (remaining after cc-resource-cleanup) ───────────
declare -A seen_infra_ids
while IFS= read -r region; do
  while IFS= read -r infra_id; do
    [[ -z "$infra_id" ]] && continue
    [[ "${seen_infra_ids[$infra_id]+_}" ]] && continue
    seen_infra_ids[$infra_id]=1

    # Skip if live CD holds this infra ID
    if echo "$live_infra_ids" | grep -qxF "$infra_id"; then
      continue
    fi

    resources=$(get_infra_resources "$PROFILE" "$region" "$infra_id")
    count=$(echo "$resources" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
    if [[ "$count" -gt 0 ]]; then
      append_item "$(python3 -c "
import json, sys
print(json.dumps({
  'resource': '${infra_id}',
  'type': 'aws_tagged_resources',
  'origin': 'Collective ClusterDeployment (infra ID: ${infra_id}) — cc-resource-cleanup leftover',
  'region': '${region}',
  'resource_count': ${count},
  'why_orphaned': 'Tagged AWS resources remain after cc-resource-cleanup; no active ClusterDeployment found',
  'confidence': 'MEDIUM',
  'action': 'hiveutil_deprovision',
  'infra_id': '${infra_id}'
}))")"
    fi
  done < <(get_cluster_tag_keys "$PROFILE" "$region" || true)
done <<< "$regions"

# ── Scan IAM roles and instance profiles (global) ────────────────────────────
# Flag IAM roles/profiles whose name contains a known infra ID with no active CD.
iam_roles=$(aws iam list-roles --profile "$PROFILE" --output json 2>/dev/null \
  | python3 -c "import sys,json; [print(r['RoleName']) for r in json.load(sys.stdin).get('Roles',[])]" || true)
iam_profiles=$(aws iam list-instance-profiles --profile "$PROFILE" --output json 2>/dev/null \
  | python3 -c "import sys,json; [print(p['InstanceProfileName']) for p in json.load(sys.stdin).get('InstanceProfiles',[])]" || true)

python3 - "$TMPFILE" "$live_infra_ids" <<PYEOF
import json, sys
path = sys.argv[1]
live_ids = set(line for line in sys.argv[2].splitlines() if line)

iam_roles = """${iam_roles}""".splitlines()
iam_profiles = """${iam_profiles}""".splitlines()

with open(path) as f:
    items = json.load(f)

for name in iam_roles:
    # Flag roles named after cluster infra IDs that are no longer active
    for infra_id in [n for n in name.split('-') if len(n) > 6]:
        candidate = '-'.join(name.split('-')[:6])  # approximate infra ID prefix
        break
    # Only flag roles that look like cluster roles (contain known pattern)
    if not any(x in name for x in ['-worker-', '-master-', '-bootstrap', '-cloud-credentials']):
        continue
    # Check if the name contains any live infra ID prefix
    if any(live_id in name for live_id in live_ids):
        continue
    items.append({
        "resource": name,
        "type": "iam_role",
        "origin": "IAM role created for a Hive/OCP cluster that may have been deprovisioned",
        "why_orphaned": "Role name matches cluster pattern but no active ClusterDeployment infra ID found",
        "confidence": "MEDIUM",
        "action": "iam_delete_role",
    })

for name in iam_profiles:
    if not any(x in name for x in ['-worker-', '-master-', '-bootstrap']):
        continue
    if any(live_id in name for live_id in live_ids):
        continue
    items.append({
        "resource": name,
        "type": "iam_instance_profile",
        "origin": "IAM instance profile created for a Hive/OCP cluster that may have been deprovisioned",
        "why_orphaned": "Profile name matches cluster pattern but no active ClusterDeployment infra ID found",
        "confidence": "MEDIUM",
        "action": "iam_delete_instance_profile",
    })

with open(path, "w") as f:
    json.dump(items, f, indent=2)
PYEOF

# ── Scan managed-velero-backups-* S3 buckets ─────────────────────────────────
while IFS= read -r bucket; do
  [[ -z "$bucket" ]] && continue
  infra_id=$(get_velero_bucket_infra_id "$PROFILE" "$bucket")
  [[ -z "$infra_id" ]] && continue

  created=$(get_bucket_creation_date "$PROFILE" "$bucket")

  if [[ "$infra_id" == rosa-* ]]; then
    # ROSA cluster: check EC2 tags AND Route53
    has_ec2=false
    while IFS= read -r region; do
      if infra_id_has_ec2_resources "$PROFILE" "$region" "$infra_id"; then
        has_ec2=true
        break
      fi
    done <<< "$regions"

    has_route53=false
    if route53_zone_exists_for_infra "$PROFILE" "$infra_id"; then
      has_route53=true
    fi

    if [[ "$has_ec2" == "false" && "$has_route53" == "false" ]]; then
      append_item "$(python3 -c "
import json
print(json.dumps({
  'resource': '${bucket}',
  'type': 's3_velero_auto',
  'origin': 'ROSA cluster ${infra_id} — ACM hub with cluster-backup enabled',
  'created': '${created}',
  'why_orphaned': 'No EC2 instances or Route53 hosted zone found for ${infra_id} — cluster removed from AWS',
  'confidence': 'HIGH',
  'action': 's3_delete',
  'infra_id': '${infra_id}'
}))")"
    fi
  else
    # Hive-deployed: check collective ClusterDeployments
    if ! echo "$live_infra_ids" | grep -qxF "$infra_id"; then
      confidence="HIGH"
      [[ -z "$live_infra_ids" ]] && confidence="MEDIUM"
      append_item "$(python3 -c "
import json
print(json.dumps({
  'resource': '${bucket}',
  'type': 's3_velero_auto',
  'origin': 'Hive-deployed cluster (infra ID: ${infra_id}) — ACM hub with cluster-backup enabled',
  'created': '${created}',
  'why_orphaned': 'Infra ID ${infra_id} not found in active collective ClusterDeployments',
  'confidence': '${confidence}',
  'action': 's3_delete',
  'infra_id': '${infra_id}'
}))")"
    fi
  fi
done < <(list_s3_buckets_matching "$PROFILE" "managed-velero-backups-")

# ── Scan manually-named velero buckets (HUMAN REVIEW) ────────────────────────
all_buckets=$(aws s3 ls --profile "$PROFILE" 2>/dev/null | awk '{print $3}')
while IFS= read -r bucket; do
  [[ -z "$bucket" ]] && continue
  # Skip managed-velero-backups (handled above) and image-registry (tagged, handled above)
  [[ "$bucket" == managed-velero-backups-* ]] && continue
  [[ "$bucket" == *-image-registry-* ]] && continue

  # Check if bucket has velero.io/backup-location tag (indicates manual velero bucket)
  tags=$(aws s3api get-bucket-tagging --bucket "$bucket" --profile "$PROFILE" 2>/dev/null || echo '{"TagSet":[]}')
  is_velero=$(echo "$tags" | python3 -c "
import sys,json
tags = {t['Key']:t['Value'] for t in json.load(sys.stdin).get('TagSet',[])}
print('true' if 'velero.io/backup-location' in tags else 'false')
")
  if [[ "$is_velero" == "true" ]]; then
    created=$(get_bucket_creation_date "$PROFILE" "$bucket")
    append_item "$(python3 -c "
import json
print(json.dumps({
  'resource': '${bucket}',
  'type': 's3_velero_manual',
  'origin': 'Manually pre-created velero backup bucket — no standardized cluster linkage tags',
  'created': '${created}',
  'why_orphaned': 'Cannot determine cluster ownership from AWS metadata alone',
  'confidence': 'HUMAN_REVIEW',
  'action': 's3_delete_force'
}))")"
  fi
done <<< "$all_buckets"

# ── Output ────────────────────────────────────────────────────────────────────
cat "$TMPFILE"
rm -f "$TMPFILE"
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
bats tests/test_scan_orphans.bats
```

- [ ] **Step 5: Commit**

```bash
git add scripts/scan-orphans.sh tests/test_scan_orphans.bats
git commit -m "feat: add full orphan scan script with tests"
```

---

### Task 11: Knowledge base initial content

**Files:**
- Populate: `knowledge/orphan-patterns.md`
- Populate: `knowledge/active-signatures.md`

- [ ] **Step 1: Populate orphan-patterns.md with known patterns from investigation**

```markdown
# Orphan Patterns

Patterns confirmed to indicate orphaned resources. Updated after each cleanup run.
Claude reads this file at the start of investigate-orphans to improve confidence scoring.

## S3 Buckets — OADP Auto-generated

- Pattern: `managed-velero-backups-<uuid>` with tag `velero.io/infrastructureName=rosa-*`
  AND no `kubernetes.io/cluster/<infra_id>=owned` EC2 tags in any region
  AND no Route53 hosted zone containing the infra ID
  → Confidence: HIGH
  → Origin: ROSA cluster used as ACM hub with cluster-backup enabled, since decommissioned
  → Confirmed: 2026-03-25 (46 buckets found, all rosa-* prefix)

## ClusterDeployments

- Pattern: `DeprovisionFailed` with condition `DeprovisionLaunchError: AuthenticationFailed`
  → The AWS credentials used to provision the cluster have expired or been rotated
  → Hive cannot deprovision — manual finalizer removal + AWS resource check required
  → Confirmed: 2026-03-25 (25 CDs found, some 4+ years old)
```

- [ ] **Step 2: Populate active-signatures.md with known active resources**

```markdown
# Active Resource Signatures

Known active resource signatures — do NOT flag these as orphaned.
Claude reads this file at the start of investigate-orphans to avoid false positives.

## S3 Buckets — Manually Pre-created Velero

The following bucket naming patterns are known manually pre-created velero buckets.
These should be flagged as HUMAN REVIEW (not auto-deleted) since they have no
standardized cluster linkage tags:
- `*-velero-backup` (e.g. vb-velero-backup, se-velero-backup)
- `*-acm-backup` (e.g. rj-acm-backup)
```

- [ ] **Step 3: Commit**

```bash
git add knowledge/
git commit -m "docs: populate knowledge base with initial patterns from investigation"
```

---

### Task 12: `investigate-orphans` skill

**Files:**
- Create: `skills/clusterpool-cleanup/investigate-orphans.md`

- [ ] **Step 1: Create skill file**

`skills/clusterpool-cleanup/investigate-orphans.md`:
```markdown
---
name: clusterpool-cleanup:investigate-orphans
description: Run after cd-cleanup and cc-resource-cleanup to scan for anything still orphaned across all resource types. Scans broadly including ROSA-based ACM hubs. Outputs report + manifest. Read-only — no destructive actions.
---

# investigate-orphans

Scan for orphaned resources across all types. Run after cd-cleanup and cc-resource-cleanup.

## Load knowledge base

Read ALL files under `<repo>/knowledge/` to inform confidence scoring:
- `<repo>/knowledge/orphan-patterns.md`
- `<repo>/knowledge/active-signatures.md`
- All files under `<repo>/knowledge/run-history/` (for historical context)

Note known patterns — use them to boost confidence on matching resources and
avoid false positives on signatures known to be active.

## Pre-flight

1. Ask: "AWS read-only profile? (default: aws-acm-dev11-readonly):" — store as RO_PROFILE
2. Run: `aws sts get-caller-identity --profile <RO_PROFILE>`
   - If fails: "Invalid credentials for profile '<RO_PROFILE>'" — STOP

3. Attempt collective access:
   - Ask: "Collective cluster namespace? (default: app):" — store as NAMESPACE
   - Run: `kubectl get clusterpool -n <NAMESPACE>`
   - If fails: warn "Collective cluster unreachable — ClusterDeployment cross-referencing
     will be skipped. ROSA bucket checks will still run." — continue

4. Check manifest at /tmp/clusterpool-cleanup-manifest.json:
   - Run: `bash <repo>/scripts/lib/manifest.sh manifest_get_cc_resource_cleanup_run /tmp/clusterpool-cleanup-manifest.json`
   - If output is `false` or manifest absent: warn "cc-resource-cleanup has not been run this session.
     Tagged AWS resources may still be present. Consider running clusterpool-cleanup:full instead."

## Scan

Run: `bash <repo>/scripts/scan-orphans.sh --profile <RO_PROFILE> --namespace <NAMESPACE>`

Parse the JSON array output. For each item:
- Apply knowledge base patterns to adjust confidence if applicable
- Note origin, why_orphaned, confidence, and recommended action

## Write manifest

Initialize manifest: `bash <repo>/scripts/lib/manifest.sh manifest_init /tmp/clusterpool-cleanup-manifest.json`

For each orphaned item, add to manifest:
`bash <repo>/scripts/lib/manifest.sh manifest_add_item /tmp/clusterpool-cleanup-manifest.json '<item-json>'`

## Output report

Print human-readable report to stdout. For each item:

```
Resource:           <resource>
Type:               <type description>
Origin:             <origin>
Created:            <created>
Why orphaned:       <why_orphaned>
Confidence:         <confidence>
Recommended action: <action description>
---
```

## Update knowledge base

If you observed any new patterns during the scan (e.g. a new bucket prefix, a new
infra ID naming convention), append them to `knowledge/orphan-patterns.md`.

## Summary

```
investigate-orphans summary:
  Resources scanned:            N
  Orphaned (high confidence):   N
  Orphaned (medium confidence): N
  Human review required:        N
  Manifest written to:          /tmp/clusterpool-cleanup-manifest.json
```
```

- [ ] **Step 2: Test manually in Claude Code**

The symlink from Task 8 covers this skill already. Verify: all of knowledge/ is read, scan runs, report prints with full context per item (including CD items when collective is reachable), manifest is written.

- [ ] **Step 3: Commit**

```bash
git add skills/clusterpool-cleanup/investigate-orphans.md
git commit -m "feat: add investigate-orphans Claude skill"
```

---

### Task 13: `cleanup-orphans` skill

**Files:**
- Create: `skills/clusterpool-cleanup/cleanup-orphans.md`

- [ ] **Step 1: Create skill file**

`skills/clusterpool-cleanup/cleanup-orphans.md`:
```markdown
---
name: clusterpool-cleanup:cleanup-orphans
description: Act on a saved manifest from investigate-orphans. Presents expand/select/deselect UI grouped by confidence, single confirm before performing any deletions. Safety re-check per item before deletion.
---

# cleanup-orphans

Act on the manifest from investigate-orphans.

## Pre-flight

1. Ask: "Collective cluster namespace? (default: app):" — store as NAMESPACE
2. Run: `kubectl get clusterpool -n <NAMESPACE>`
   - If fails: "Please log in first: oc login <api-url>" — STOP

3. Ask: "hiveutil path? (default: ~/DEV/openshift/hive/bin/hiveutil):" — store as HIVEUTIL
   - Verify: `[[ -x "$HIVEUTIL" ]]`
   - If not found: warn "hiveutil not found — hiveutil_deprovision items will be skipped if selected"
   (soft dependency — proceed even if missing; skip those items at execution time)

4. Load manifest:
   - If invoked via `full`: use /tmp/clusterpool-cleanup-manifest.json (no prompt)
   - Otherwise: check /tmp/clusterpool-cleanup-manifest.json exists; if not, ask for path

## Present cleanup plan

Group items from manifest by confidence level:

```
=== cleanup-orphans Plan ===

[HIGH CONFIDENCE]
 [1] ✓  N items

[MEDIUM CONFIDENCE]
 [2] ✓  N items

[HUMAN REVIEW REQUIRED — no automated safety check]
 [3] ✗  N items (deselected by default)

Commands: <number> to toggle group, e<number> to expand, <number><letter> to toggle item, Enter to proceed
```

When expanded, show full resource detail from manifest.

If user selects any HUMAN REVIEW items, show:
"⚠ N selected items have no automated safety check (no cluster linkage).
 Expand to review each before proceeding."

## AWS credentials

Ask: "AWS write profile? (default: aws-acm-dev11):" — store as WRITE_PROFILE
Run: `aws sts get-caller-identity --profile <WRITE_PROFILE>` — verify

## Confirm

If HUMAN REVIEW items selected:
  "Proceed with selected items? (includes N items with no safety check) (y/n)"
Else:
  "Proceed with selected items? (y/n)"
If n: STOP.

## Execute

For each selected standard item (not HUMAN REVIEW), immediately before acting:
- Re-query collective and/or AWS to verify resource is still orphaned
- If state changed: skip, note as "Skipped (state changed)"

Actions by type:
- `s3_delete`: `aws s3 rb --force s3://<resource> --profile <WRITE_PROFILE>`
- `hiveutil_deprovision`: `<HIVEUTIL> aws-tag-deprovision kubernetes.io/cluster/<infra_id>=owned --region <region>`
  - If HIVEUTIL was not found during pre-flight: skip this item, count as Failed with message
    "hiveutil not available — cannot deprovision <infra_id>. Run cc-resource-cleanup manually."
- `cd_remove_finalizer`: `kubectl patch clusterdeployment -n <namespace> <name> -p '{"metadata":{"finalizers":[]}}' --type=merge`
- `cd_delete`: `kubectl delete clusterdeployment -n <namespace> <name>`

For HUMAN REVIEW items (if selected): direct `aws s3 rb --force` — no safety check.

## Update knowledge base

After execution, append run summary to `knowledge/run-history/YYYY-MM-DD-run.md`.
If user decisions revealed new patterns (e.g. confirmed safe to delete a certain bucket
type), update `knowledge/orphan-patterns.md`.

## Summary

```
cleanup-orphans summary:
  Cleaned:                 N items
  Skipped (state changed): N items
  Failed:                  N items
```
```

- [ ] **Step 2: Test manually in Claude Code**

The symlink from Task 8 covers this skill already. Verify: manifest is loaded, UI shows items grouped by confidence (including any CD items from investigate-orphans), HUMAN REVIEW warning appears when selected, confirm prompt is correct, safety re-checks run before each deletion, knowledge base updated after run.

- [ ] **Step 3: Commit**

```bash
git add skills/clusterpool-cleanup/cleanup-orphans.md
git commit -m "feat: add cleanup-orphans Claude skill"
```

---

### Task 14: `full` skill

**Files:**
- Create: `skills/clusterpool-cleanup/full.md`

- [ ] **Step 1: Create skill file**

`skills/clusterpool-cleanup/full.md`:
```markdown
---
name: clusterpool-cleanup:full
description: Run all four cleanup steps in sequence: cd-cleanup → cc-resource-cleanup → investigate-orphans → cleanup-orphans. Three confirmation points — one before each destructive phase. AWS credentials prompted at point of first use.
---

# clusterpool-cleanup:full

Run the complete cleanup sequence.

## Pre-flight (shared)

1. Ask: "Collective cluster namespace? (default: app):" — store as NAMESPACE
2. Run: `kubectl get clusterpool -n <NAMESPACE>`
   - If fails: "Please log in first: oc login <api-url>" — STOP

Initialize a fresh manifest:
`bash <repo>/scripts/lib/manifest.sh manifest_init /tmp/clusterpool-cleanup-manifest.json`

---

## Phase 1: cd-cleanup

Follow all steps from `clusterpool-cleanup:cd-cleanup` using NAMESPACE above.
(Confirmation point 1 before any deletions)

Record phase 1 summary.

---

## Phase 2: cc-resource-cleanup

Follow all steps from `clusterpool-cleanup:cc-resource-cleanup` using NAMESPACE above.
(Confirmation point 2 before any deletions)

When prompted for AWS write profile, store the answer as WRITE_PROFILE.
When prompted for hiveutil path, store the answer as HIVEUTIL_PATH.
**Reuse WRITE_PROFILE and HIVEUTIL_PATH in Phase 4 (cleanup-orphans) — do not re-prompt either.**

After completion, set manifest field:
`bash <repo>/scripts/lib/manifest.sh manifest_set_cc_resource_cleanup_run /tmp/clusterpool-cleanup-manifest.json true`

Record phase 2 summary.

---

## Phase 3: investigate-orphans

Follow all steps from `clusterpool-cleanup:investigate-orphans` using NAMESPACE above.
Skip the manifest cc_resource_cleanup_run warning (we just ran it).
Write findings to /tmp/clusterpool-cleanup-manifest.json.

Record phase 3 summary.

---

## Phase 4: cleanup-orphans

Follow all steps from `clusterpool-cleanup:cleanup-orphans` using NAMESPACE above.
Read manifest from /tmp/clusterpool-cleanup-manifest.json (skip path prompt).
Use WRITE_PROFILE from Phase 2 — skip the AWS write profile prompt.
Use HIVEUTIL_PATH from Phase 2 — skip the hiveutil path prompt.
(Confirmation point 3 before any deletions)

Record phase 4 summary.

---

## Full summary

Aggregate all four phase summaries:

```
full summary:
  CD objects cleaned:          N
  AWS resource groups cleaned: N
  Remaining orphans found:     N
  Remaining orphans cleaned:   N
  Skipped (state changed):     N
  Failed:                      N
```
```

- [ ] **Step 2: Test manually in Claude Code**

The symlink from Task 8 covers this skill already. Verify: all four phases run in sequence, three confirm prompts appear, AWS write profile is prompted once in Phase 2 and reused in Phase 4, manifest is passed correctly between phases, aggregated summary is accurate.

- [ ] **Step 3: Commit and push**

```bash
git add skills/clusterpool-cleanup/full.md
git commit -m "feat: add full orchestration Claude skill"
git push
```

---

## Skill Registration

The skills in `skills/clusterpool-cleanup/` are Claude Code superpowers skill files.
Done once in Task 8. The symlink covers all skills in the directory:

```bash
PLUGIN_DIR=$(ls -d ~/.claude/plugins/cache/claude-plugins-official/superpowers/*/skills 2>/dev/null | tail -1)
ln -sf "$(pwd)/skills/clusterpool-cleanup" "${PLUGIN_DIR}/clusterpool-cleanup"
```

Verify all five skills load:
```bash
# In Claude Code, invoke each:
# /clusterpool-cleanup:cd-cleanup
# /clusterpool-cleanup:cc-resource-cleanup
# /clusterpool-cleanup:investigate-orphans
# /clusterpool-cleanup:cleanup-orphans
# /clusterpool-cleanup:full
```

Alternatively, use the `superpowers:writing-skills` skill which handles registration automatically.

---

## Testing Checklist

Before marking implementation complete, verify each skill end-to-end:

- [ ] `cd-cleanup`: scans, presents UI, confirm, executes, shows summary
- [ ] `cc-resource-cleanup`: hiveutil update check, scans, presents UI, confirm, executes, shows summary
- [ ] `investigate-orphans`: reads knowledge base, scans, writes manifest, prints report
- [ ] `cleanup-orphans`: loads manifest, UI with confidence groups, HUMAN REVIEW warning, safety re-checks, knowledge base update
- [ ] `full`: all four phases in sequence, three confirm points, aggregated summary
- [ ] All bash tests pass: `bats tests/`
