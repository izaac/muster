#!/usr/bin/env bats
# Unit tests for the Phase 1 handoff adapter in lib/handoff.sh.
# Pure function over exported cluster facts: no cluster, no network.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  . "$ROOT/lib/util.sh"
  # shellcheck source=../lib/handoff.sh
  . "$ROOT/lib/handoff.sh"

  export MUSTER_HOSTNAME="10.0.0.5.sslip.io"
  export MUSTER_KUBECONFIG="/tmp/kc.yaml"
  export MUSTER_PASSWORD="s3cret"
}

@test "env handoff emits the dashboard URL" {
  run handoff_write env
  [ "$status" -eq 0 ]
  [[ "$output" == *"TEST_BASE_URL=https://10.0.0.5.sslip.io/dashboard"* ]]
}

@test "env handoff emits hostname, kubeconfig, and password" {
  run handoff_write env
  [[ "$output" == *"RANCHER_HOSTNAME=10.0.0.5.sslip.io"* ]]
  [[ "$output" == *"KUBECONFIG=/tmp/kc.yaml"* ]]
  [[ "$output" == *"TEST_PASSWORD=s3cret"* ]]
}

@test "env is the default format when none is given" {
  run handoff_write
  [ "$status" -eq 0 ]
  [[ "$output" == *"TEST_BASE_URL="* ]]
}

@test "env handoff falls back to the default password when unset" {
  unset MUSTER_PASSWORD
  run handoff_write env
  [[ "$output" == *"TEST_PASSWORD=password1234"* ]]
}

@test "env handoff fails closed when cmd_up has not exported a hostname" {
  unset MUSTER_HOSTNAME
  run handoff_write env
  [ "$status" -ne 0 ]
}

@test "cypress handoff emits the upstream base-config env contract" {
  run handoff_write cypress
  [ "$status" -eq 0 ]
  [[ "$output" == *"TEST_BASE_URL=https://10.0.0.5.sslip.io/dashboard"* ]]
  [[ "$output" == *"TEST_USERNAME=admin"* ]]
  [[ "$output" == *"CATTLE_BOOTSTRAP_PASSWORD=s3cret"* ]]
  [[ "$output" == *"TEST_PASSWORD=s3cret"* ]]
  [[ "$output" == *"API=https://10.0.0.5.sslip.io"* ]]
}

@test "cypress handoff honours an overridden username" {
  export MUSTER_USERNAME="operator"
  run handoff_write cypress
  [[ "$output" == *"TEST_USERNAME=operator"* ]]
}

@test "json handoff emits a single object with the cluster facts" {
  run handoff_write json
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "{" ]
  [ "${lines[${#lines[@]}-1]}" = "}" ]
  [[ "$output" == *'"baseUrl": "https://10.0.0.5.sslip.io/dashboard"'* ]]
  [[ "$output" == *'"api": "https://10.0.0.5.sslip.io"'* ]]
  [[ "$output" == *'"kubeconfig": "/tmp/kc.yaml"'* ]]
  [[ "$output" == *'"password": "s3cret"'* ]]
}

@test "json handoff escapes a backslash and a double quote in a value" {
  export MUSTER_PASSWORD='a"b\c'
  run handoff_write json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"password": "a\"b\\c"'* ]]
}

@test "an unknown format is rejected" {
  run handoff_write bogus
  [ "$status" -ne 0 ]
}
