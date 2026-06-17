#!/usr/bin/env bats
# Unit tests for lib/util.sh pure helpers.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  . "$ROOT/lib/util.sh"
}

@test "is_true accepts every truthy spelling and case" {
  local v
  for v in 1 true TRUE True tRuE yes YES Yes yEs on ON On oN; do
    run is_true "$v"
    [ "$status" -eq 0 ] || {
      echo "expected truthy: '$v'"
      false
    }
  done
}

@test "is_true ignores surrounding whitespace" {
  local v
  for v in " true" "true " "  1  " "	yes" "on	" " TRUE " "
true
"; do
    run is_true "$v"
    [ "$status" -eq 0 ] || {
      echo "expected truthy with ws: '$v'"
      false
    }
  done
}

@test "is_true rejects falsy, empty, and near-misses" {
  local v
  for v in 0 false FALSE no NO off OFF "" " " "	" garbage 2 10 "1.0" \
    y t yep yess "true false" "1 0" enable enabled disabled nul null \
    "o n" "ye s" "-1" "00"; do
    run is_true "$v"
    [ "$status" -ne 0 ] || {
      echo "expected falsy: '$v'"
      false
    }
  done
}

@test "is_true on unset arg is falsy, not an error" {
  run is_true
  [ "$status" -ne 0 ]
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
