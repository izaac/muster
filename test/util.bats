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

# --- is_rootless_podman_sock -------------------------------------------------

@test "is_rootless_podman_sock matches per-user runtime sockets" {
  run is_rootless_podman_sock /run/user/1000/podman/podman.sock
  [ "$status" -eq 0 ]
}

@test "is_rootless_podman_sock rejects the system socket" {
  run is_rootless_podman_sock /run/podman/podman.sock
  [ "$status" -ne 0 ]
}

# --- is_podman_host ----------------------------------------------------------

@test "is_podman_host is true when DOCKER_HOST names a podman socket" {
  is_podman_cli() { return 1; }
  DOCKER_HOST="unix:///run/user/1000/podman/podman.sock" run is_podman_host
  [ "$status" -eq 0 ]
}

@test "is_podman_host is false for real docker (no shim, non-podman host)" {
  is_podman_cli() { return 1; }
  DOCKER_HOST="unix:///var/run/docker.sock" run is_podman_host
  [ "$status" -ne 0 ]
}

# --- resolve_docker_host -----------------------------------------------------

# Bind a real AF_UNIX socket so the [ -S ] probe passes.
_mk_sock() {
  local path="$1"
  python3 - "$path" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
PY
}

@test "resolve_docker_host switches a rootless DOCKER_HOST to the rootful socket" {
  is_podman_host() { return 0; }
  local d; d="$(mktemp -d)"
  _mk_sock "$d/rootful.sock"
  export DOCKER_HOST="unix:///run/user/1000/podman/podman.sock"
  MUSTER_ROOTFUL_SOCK="$d/rootful.sock" resolve_docker_host
  [ "$DOCKER_HOST" = "unix://$d/rootful.sock" ]
  rm -rf "$d"
}

@test "resolve_docker_host adopts the rootful socket when DOCKER_HOST is unset" {
  is_podman_host() { return 0; }
  local d; d="$(mktemp -d)"
  _mk_sock "$d/rootful.sock"
  unset DOCKER_HOST
  MUSTER_ROOTFUL_SOCK="$d/rootful.sock" resolve_docker_host
  [ "$DOCKER_HOST" = "unix://$d/rootful.sock" ]
  rm -rf "$d"
}

@test "resolve_docker_host leaves an explicit rootful endpoint untouched" {
  is_podman_host() { return 0; }
  export DOCKER_HOST="unix:///run/podman/podman.sock"
  resolve_docker_host
  [ "$DOCKER_HOST" = "unix:///run/podman/podman.sock" ]
}

@test "resolve_docker_host is a no-op on a real docker host" {
  is_podman_host() { return 1; }
  export DOCKER_HOST="unix:///var/run/docker.sock"
  resolve_docker_host
  [ "$DOCKER_HOST" = "unix:///var/run/docker.sock" ]
}

@test "resolve_docker_host dies when a podman host has no rootful socket" {
  is_podman_host() { return 0; }
  local d; d="$(mktemp -d)"
  run env MUSTER_ROOTFUL_SOCK="$d/missing.sock" \
    DOCKER_HOST="unix:///run/user/1000/podman/podman.sock" \
    bash -c '. "'"$ROOT"'/lib/util.sh"; is_podman_host() { return 0; }; resolve_docker_host'
  [ "$status" -ne 0 ]
  [[ "$output" == *"rootful socket"* ]]
  rm -rf "$d"
}
