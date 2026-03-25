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

@test "get_cluster_tag_keys: returns kubernetes.io/cluster/ infra IDs for region" {
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
