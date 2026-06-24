#!/usr/bin/env bats
# Unit tests for drivers/existing.sh. Pure input validation + hook wiring: no
# real cluster. driver_up's reachability probe is exercised with a stubbed
# kubectl so the success path runs without a live API server.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  . "$ROOT/lib/util.sh"
  # shellcheck source=../drivers/existing.sh
  . "$ROOT/drivers/existing.sh"

  INSTANCE="e2e"
  KC="$BATS_TEST_TMPDIR/kubeconfig"
  : >"$KC"
  KUBECONFIG="$KC"
  RANCHER_HOST="rancher.example.com"
  EXTERNAL="false"
}

# --- kubeconfig --------------------------------------------------------------

@test "driver_kubeconfig prints the caller-supplied path" {
  run driver_kubeconfig
  [ "$status" -eq 0 ]
  [ "$output" = "$KC" ]
}

@test "driver_kubeconfig is refused when KUBECONFIG is unset" {
  KUBECONFIG=""
  run driver_kubeconfig
  [ "$status" -ne 0 ]
  [[ "$output" == *"--kubeconfig"* ]]
}

@test "driver_kubeconfig is refused when the file is unreadable" {
  KUBECONFIG="$BATS_TEST_TMPDIR/does-not-exist"
  run driver_kubeconfig
  [ "$status" -ne 0 ]
  [[ "$output" == *"not readable"* ]]
}

# --- endpoint ----------------------------------------------------------------

@test "driver_endpoint prints the caller-supplied hostname" {
  run driver_endpoint
  [ "$status" -eq 0 ]
  [ "$output" = "rancher.example.com" ]
}

@test "driver_endpoint is refused when RANCHER_HOST is unset" {
  RANCHER_HOST=""
  run driver_endpoint
  [ "$status" -ne 0 ]
  [[ "$output" == *"--rancher-host"* ]]
}

# --- driver_installs_rancher must stay undefined (core runs helm) ------------

@test "driver_installs_rancher is NOT declared so the core helm path runs" {
  ! declare -F driver_installs_rancher >/dev/null
}

# --- down is a no-op ---------------------------------------------------------

@test "driver_down is a no-op and succeeds" {
  run driver_down
  [ "$status" -eq 0 ]
  [[ "$output" == *"untouched"* ]]
}

# --- up validation -----------------------------------------------------------

@test "driver_up rejects external mode" {
  EXTERNAL="true"
  run driver_up
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not support --external"* ]]
}

@test "driver_up requires a kubeconfig" {
  KUBECONFIG=""
  kubectl() { return 0; }
  export -f kubectl
  run driver_up
  [ "$status" -ne 0 ]
  [[ "$output" == *"--kubeconfig"* ]]
}

@test "driver_up requires a rancher host" {
  RANCHER_HOST=""
  kubectl() { return 0; }
  export -f kubectl
  run driver_up
  [ "$status" -ne 0 ]
  [[ "$output" == *"--rancher-host"* ]]
}

@test "driver_up fails when the cluster is unreachable" {
  kubectl() { return 1; }
  export -f kubectl
  run driver_up
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot reach the cluster"* ]]
}

@test "driver_up succeeds when inputs are valid and the cluster is reachable" {
  kubectl() { return 0; }
  export -f kubectl
  run driver_up
  [ "$status" -eq 0 ]
  [[ "$output" == *"serving rancher at"* ]]
}
