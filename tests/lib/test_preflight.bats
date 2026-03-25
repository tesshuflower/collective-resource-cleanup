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
  echo '{"items":[{"metadata":{"name":"app-pool"}}]}' \
    > "${BATS_TEST_DIRNAME}/../fixtures/kubectl/get_clusterpool_-n_app_-o_json.json"
  run verify_collective_access "app"
  [ "$status" -eq 0 ]
}

@test "verify_collective_access: returns 1 when cluster unreachable" {
  # Remove fixture if it exists
  rm -f "${BATS_TEST_DIRNAME}/../fixtures/kubectl/get_clusterpool_-n_app_-o_json.json"
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
