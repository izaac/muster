#!/usr/bin/env bats
# Entrypoint tests for the --external wiring in cmd_up.
#
# cmd_up is sourced out of the real entrypoint so the code under test is the code
# that ships; the substrate and tunnel are stubbed. Nothing provisions anything.
#
# cmd_up is invoked in a subshell like the entrypoint does, and `driver_up` fails,
# so these also pin the cleanup contract: the EXIT trap must tear down a tunnel
# this run started, and `set -e` inside the driver must stay live.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  cd "$ROOT"
  MARK="$BATS_TEST_TMPDIR/mark"
  : >"$MARK"
  export MARK
}

# _run_cmd_up <body> - source muster, install the stubs in <body>, then run
# cmd_up in a subshell. The child exits with cmd_up's status, so the caller can
# assert it and read what the stubs recorded.
_run_cmd_up() {
  local body="$1"
  run_status=0
  bash -c '
    . ./muster help >/dev/null 2>&1
    branches_apply_k3s_image() { :; }
    log_info() { :; }
    tunnel_up() { printf "up\n" >>"$MARK"; printf "https://mock.trycloudflare.com"; }
    tunnel_down() { printf "down%s\n" "${1:-}" >>"$MARK"; }
    # A failure in here must abort cmd_up with errexit still on. If it were
    # wrapped in `if !` or `||`, the shell would ignore -e here, `false` would
    # fall through, and after-fail would be recorded.
    driver_up() {
      printf "host=%s\n" "${EXTERNAL_HOSTNAME:-}" >>"$MARK"
      false
      printf "after-fail\n" >>"$MARK"
    }
    '"$body"'
    ( cmd_up )
  ' || run_status=$?
}

@test "a pre-configured EXTERNAL_HOSTNAME starts no tunnel and owns no cleanup" {
  _run_cmd_up 'EXTERNAL=true; EXTERNAL_HOSTNAME=rancher.example.com'
  [ "$run_status" -eq 1 ]
  grep -q '^host=rancher.example.com$' "$MARK"
  ! grep -q '^up$' "$MARK"
  ! grep -q '^down' "$MARK"
}

@test "the tunnel started by the run is torn down when provisioning fails" {
  _run_cmd_up 'EXTERNAL=true; unset EXTERNAL_HOSTNAME'
  [ "$run_status" -eq 1 ]
  grep -q '^up$' "$MARK"
  grep -q '^host=mock.trycloudflare.com$' "$MARK"
  # The EXIT trap fired even though the failure happened inside driver_up.
  grep -q '^down$' "$MARK"
  # ... and errexit was live inside driver_up, so nothing after `false` ran.
  ! grep -q '^after-fail$' "$MARK"
}

@test "a non-external run never touches the tunnel, even when provisioning fails" {
  _run_cmd_up 'EXTERNAL=false'
  [ "$run_status" -eq 1 ]
  ! grep -q '^up$' "$MARK"
  ! grep -q '^down' "$MARK"
  ! grep -q '^after-fail$' "$MARK"
}
