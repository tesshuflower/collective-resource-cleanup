#!/usr/bin/env bash
# Mock AWS CLI for testing. Set MOCK_AWS_RESPONSES dir before sourcing.
# Fixture filename encoding: spaces→_, /→_, ,→_, =→_
aws() {
  local key="$*"
  key="${key// /_}"
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
