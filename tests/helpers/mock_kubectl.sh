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
