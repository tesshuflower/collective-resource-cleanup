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

# Prompt for and verify AWS profile. Returns 1 with error message if invalid.
# Usage: prompt_and_verify_aws_profile <suggested-default>
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
# Usage: prompt_and_verify_collective_access <suggested-default>
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
