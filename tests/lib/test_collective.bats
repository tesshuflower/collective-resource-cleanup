#!/usr/bin/env bats

setup() {
  source "${BATS_TEST_DIRNAME}/../../scripts/lib/collective.sh"
  source "${BATS_TEST_DIRNAME}/../helpers/mock_kubectl.sh"
  export MOCK_KUBECTL_RESPONSES="${BATS_TEST_DIRNAME}/../fixtures/kubectl"
  mkdir -p "$MOCK_KUBECTL_RESPONSES"
}

@test "get_live_infra_ids: returns infra IDs of non-DeprovisionFailed CDs" {
  # Create fixture for this specific test scenario
  cat > "${MOCK_KUBECTL_RESPONSES}/get_clusterdeployment_--all-namespaces_-l_cluster.open-cluster-management.io_clusterset=live_-o_json.json" <<'EOF'
{"items":[
  {"spec":{"clusterMetadata":{"infraID":"infra-abc123"}},"status":{"provisionStatus":"Provisioned"}},
  {"spec":{"clusterMetadata":{"infraID":"infra-dead"}},"status":{"provisionStatus":"DeprovisionFailed"}}
]}
EOF
  run get_live_infra_ids "live"
  [ "$status" -eq 0 ]
  [[ "$output" == *"infra-abc123"* ]]
  [[ "$output" != *"infra-dead"* ]]
}

@test "get_deprovision_failed_cds: returns DeprovisionFailed CDs as JSON array" {
  # Create fixture for this specific test scenario
  cat > "${MOCK_KUBECTL_RESPONSES}/get_clusterdeployment_--all-namespaces_-l_cluster.open-cluster-management.io_clusterset=failed_-o_json.json" <<'EOF'
{"items":[
  {"metadata":{"name":"cd-dead","namespace":"cd-dead"},"spec":{"clusterMetadata":{"infraID":"infra-dead"}},"status":{"provisionStatus":"DeprovisionFailed"}}
]}
EOF
  run get_deprovision_failed_cds "failed"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cd-dead"* ]]
}

@test "get_stuck_provisioning_cds: only returns CDs stuck longer than threshold" {
  local old_time
  old_time=$(date -u -v-25H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
    || date -u --date='25 hours ago' '+%Y-%m-%dT%H:%M:%SZ')
  local recent_time
  recent_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  # Create fixture for this specific test scenario
  cat > "${MOCK_KUBECTL_RESPONSES}/get_clusterdeployment_--all-namespaces_-l_cluster.open-cluster-management.io_clusterset=stuck_-o_json.json" <<EOF
{"items":[
  {"metadata":{"name":"stuck-cd","namespace":"stuck-cd","creationTimestamp":"${old_time}"},"status":{"provisionStatus":"Provisioning"}},
  {"metadata":{"name":"new-cd","namespace":"new-cd","creationTimestamp":"${recent_time}"},"status":{"provisionStatus":"Provisioning"}}
]}
EOF
  run get_stuck_provisioning_cds "stuck" 24
  [ "$status" -eq 0 ]
  [[ "$output" == *"stuck-cd"* ]]
  [[ "$output" != *"new-cd"* ]]
}
