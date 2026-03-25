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
