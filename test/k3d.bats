#!/usr/bin/env bats
# Unit tests for the k3d driver's HA topology: server count, the dashboard-dist
# mount on every server, and the settle probe across servers.
#
# k3d and the container CLI are stubbed, so no cluster is created.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  . "$ROOT/lib/util.sh"
  # shellcheck source=../drivers/k3d.sh
  . "$ROOT/drivers/k3d.sh"

  INSTANCE="e2e"
  ARGS="$BATS_TEST_TMPDIR/args"
  : >"$ARGS"
  unset DASHBOARD_DIST AIRGAP K3D_SERVERS

  require_cmd() { :; }
  k3d_network() { printf 'k3d-e2e'; }
  podman_docker_sock() { :; }
  in_container() { return 1; }
  driver_endpoint() { printf 'rancher.example.com'; }
  endpoint_resolves() { return 0; }
  k3d() {
    case "$1 $2" in
      "cluster list") return 0 ;;
      "cluster create") printf '%s\n' "$*" >>"$ARGS" ;;
    esac
  }
}

@test "driver_up creates the requested number of k3d servers" {
  K3D_SERVERS=3
  run driver_up
  [ "$status" -eq 0 ]
  grep -q -- '--servers 3 --agents 0' "$ARGS"
}

@test "driver_up defaults to one server" {
  run driver_up
  [ "$status" -eq 0 ]
  grep -q -- '--servers 1 --agents 0' "$ARGS"
}

@test "the dashboard dist is mounted on every server node" {
  mkdir -p "$BATS_TEST_TMPDIR/dist"
  DASHBOARD_DIST="$BATS_TEST_TMPDIR/dist"
  K3D_SERVERS=3
  run driver_up
  [ "$status" -eq 0 ]
  grep -qF -- '@server:*' "$ARGS"
  ! grep -qF -- '@server:0' "$ARGS"
}

@test "driver_settle samples every server node, not just server-0" {
  STATS="$BATS_TEST_TMPDIR/stats"
  : >"$STATS"
  container_cli() {
    case "$1" in
      ps) printf '%s\n' k3d-e2e-server-0 k3d-e2e-server-1 k3d-e2e-server-2 ;;
      exec) printf '8\n' ;;
      stats)
        printf '%s\n' "${!#}" >>"$STATS"
        printf '10.0%%\n'
        ;;
    esac
  }
  sleep() { :; }
  run driver_settle
  [ "$status" -eq 0 ]
  grep -q 'k3d-e2e-server-0' "$STATS"
  grep -q 'k3d-e2e-server-1' "$STATS"
  grep -q 'k3d-e2e-server-2' "$STATS"
}
