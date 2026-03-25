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
