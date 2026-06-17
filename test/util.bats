#!/usr/bin/env bats
# Unit tests for lib/util.sh pure helpers.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  . "$ROOT/lib/util.sh"
}

@test "is_true accepts truthy spellings" {
  for v in 1 true TRUE Yes on ON; do
    run is_true "$v"
    [ "$status" -eq 0 ]
  done
}

@test "is_true rejects falsy and empty" {
  for v in 0 false no off "" garbage; do
    run is_true "$v"
    [ "$status" -ne 0 ]
  done
}

@test "require_cmd passes for an existing binary" {
  run require_cmd bash
  [ "$status" -eq 0 ]
}

@test "require_cmd dies for a missing binary" {
  run require_cmd definitely-not-a-real-binary-xyz
  [ "$status" -ne 0 ]
  [[ "$output" == *"required command not found"* ]]
}

@test "retry succeeds on the first passing attempt" {
  run retry 3 0 "true-cmd" -- true
  [ "$status" -eq 0 ]
  [[ "$output" == *"ready: true-cmd"* ]]
}

@test "retry gives up and dies after exhausting attempts" {
  run retry 2 0 "false-cmd" -- false
  [ "$status" -ne 0 ]
  [[ "$output" == *"not ready after 2 attempts"* ]]
}

@test "ca_bundle honours an explicit readable SSL_CERT_FILE" {
  tmp="$(mktemp)"
  SSL_CERT_FILE="$tmp" run ca_bundle
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" = "$tmp" ]
}
