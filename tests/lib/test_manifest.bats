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
