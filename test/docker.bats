#!/usr/bin/env bats
# Unit tests for drivers/docker.sh. Pure helpers + hook wiring only: no docker
# daemon, no network. The cmd_up skip path is exercised with a throwaway fake
# driver so the helm path is provably bypassed when driver_installs_rancher
# returns 0.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  . "$ROOT/lib/util.sh"
  # shellcheck source=../lib/helm.sh
  . "$ROOT/lib/helm.sh"
  # shellcheck source=../drivers/docker.sh
  . "$ROOT/drivers/docker.sh"

  INSTANCE="e2e"
  RANCHER_REPO="rancher-com-rc"
  RANCHER_IMAGE_TAG="head"
}

# --- hooks -------------------------------------------------------------------

@test "driver_installs_rancher returns 0 (skip helm in cmd_up)" {
  run driver_installs_rancher
  [ "$status" -eq 0 ]
}

@test "driver_kubeconfig prints empty (standalone rancher has none)" {
  run driver_kubeconfig
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "driver_gate and driver_settle are declared" {
  declare -F driver_gate >/dev/null
  declare -F driver_settle >/dev/null
}

@test "driver_tunnel_port mirrors the published https port" {
  [ "$(driver_tunnel_port)" = "8443" ]
  INSTANCE="e2e-1"; [ "$(driver_tunnel_port)" = "8444" ]
}

# --- port + name offsets (sharding parity with k3d) --------------------------

@test "https port offsets by instance index" {
  [ "$(docker_https_port)" = "8443" ]
  INSTANCE="e2e-1"; [ "$(docker_https_port)" = "8444" ]
  INSTANCE="e2e-2"; [ "$(docker_https_port)" = "8445" ]
}

@test "container name carries the instance id" {
  [ "$(docker_container_name)" = "muster-docker-e2e" ]
  INSTANCE="e2e-3"; [ "$(docker_container_name)" = "muster-docker-e2e-3" ]
}

@test "a bad instance is rejected" {
  INSTANCE="prod"
  run docker_index
  [ "$status" -ne 0 ]
  [[ "$output" == *"instance must be"* ]]
}

# --- driver_resolve_image: community path is helm-free -----------------------

@test "community head resolves to rancher/rancher:head with no helm" {
  RANCHER_REPO="rancher-com-rc" RANCHER_IMAGE_TAG="head"
  [ "$(driver_resolve_image)" = "rancher/rancher:head" ]
}

@test "community version pin resolves to the literal tag" {
  RANCHER_REPO="rancher-community" RANCHER_IMAGE_TAG="v2.13.3"
  [ "$(driver_resolve_image)" = "rancher/rancher:v2.13.3" ]
}

@test "com-alpha maps to Docker Hub rancher/rancher" {
  RANCHER_REPO="rancher-com-alpha" RANCHER_IMAGE_TAG="head"
  [ "$(driver_resolve_image)" = "rancher/rancher:head" ]
}

# --- driver_resolve_image: staging/prime need helm for the tag ---------------

@test "staging channel rejects without helm (cannot resolve v<chart_version>)" {
  RANCHER_REPO="rancher-latest" RANCHER_IMAGE_TAG="2.13"
  # Deterministic: simulate helm being absent by making require_cmd die for
  # helm only, so the test does not depend on the host toolchain.
  require_cmd() {
    [ "$1" = helm ] && die "required command not found: helm (stubbed absent)"
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
  }
  run driver_resolve_image
  [ "$status" -ne 0 ]
  [[ "$output" == *"helm"* ]]
}

@test "staging channel uses a pre-exported RANCHER_IMAGE_TAG_RESOLVED" {
  RANCHER_REPO="rancher-alpha" RANCHER_IMAGE_TAG="2.14"
  RANCHER_CHART_VERSION="2.14.0-alpha5"
  RANCHER_IMAGE_TAG_RESOLVED="v2.14.0-alpha5"
  [ "$(driver_resolve_image)" = "stgregistry.suse.com/rancher/rancher:v2.14.0-alpha5" ]
}

@test "prime channel maps to the gated SUSE registry" {
  RANCHER_REPO="rancher-prime" RANCHER_IMAGE_TAG="2.10.1"
  RANCHER_CHART_VERSION="2.10.1"
  RANCHER_IMAGE_TAG_RESOLVED="v2.10.1"
  [ "$(driver_resolve_image)" = "registry.suse.com/rancher/rancher:v2.10.1" ]
}

@test "an unknown repo is rejected" {
  RANCHER_REPO="bogus" RANCHER_IMAGE_TAG="head"
  run driver_resolve_image
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown RANCHER_REPO"* ]]
}

# --- endpoint ----------------------------------------------------------------

@test "endpoint is localhost:<https-port> from a host shell" {
  # Not in a container (no /.dockerenv in the bats sandbox).
  [ "$(driver_endpoint)" = "localhost:8443" ]
  INSTANCE="e2e-4"; [ "$(driver_endpoint)" = "localhost:8447" ]
}

@test "endpoint honours EXTERNAL_HOSTNAME when set" {
  EXTERNAL_HOSTNAME="rancher.example.test"
  [ "$(driver_endpoint)" = "rancher.example.test" ]
}

# --- cmd_up skip path (fake docker driver, no docker/helm needed) ------------
#
# `muster up --provider docker` must skip helm_resolve_version /
# helm_install_rancher when driver_installs_rancher returns 0. We build a
# throwaway MUSTER_HOME (a copy of the entrypoint + symlinked libs) whose
# drivers/docker.sh is a fake that no-ops the verbs and plants helm tripwires.
# Copying muster (not symlinking) is deliberate: the entrypoint derives
# MUSTER_HOME from its own path, so a copy rooted in the temp dir makes that
# dir the home and lets the fake driver win.

_fake_home() {
  local home="$1"
  mkdir -p "$home/drivers"
  cp "$ROOT/muster" "$home/muster"
  ln -s "$ROOT/lib" "$home/lib"
}

@test "cmd_up skips helm when the driver installs rancher itself" {
  local home
  home="$(mktemp -d)"
  _fake_home "$home"
  cat >"$home/drivers/docker.sh" <<'FAKE'
[ -n "${_FAKE_DOCKER:-}" ] && return 0
_FAKE_DOCKER=1
driver_up() { :; }
driver_down() { :; }
driver_kubeconfig() { printf ''; }
driver_endpoint() { printf 'fake.local:443'; }
driver_installs_rancher() { return 0; }
driver_gate() { :; }
# Tripwires: if cmd_up reaches the helm path, abort the test.
helm_resolve_version() { echo "HELM_SHOULD_NOT_RUN" >&2; exit 99; }
helm_install_rancher() { echo "HELM_SHOULD_NOT_RUN" >&2; exit 99; }
FAKE

  run "$home/muster" up --provider docker --out env
  local rc=$status
  rm -rf "$home"
  [ "$rc" -eq 0 ]
  [[ "$output" == *"TEST_BASE_URL=https://fake.local:443/dashboard"* ]]
  [[ "$output" != *"HELM_SHOULD_NOT_RUN"* ]]
}

@test "cmd_up runs helm when the driver does not install rancher" {
  # Same harness, but the fake driver omits driver_installs_rancher; the helm
  # tripwire should fire (exit 7) proving the helm path was reached.
  local home
  home="$(mktemp -d)"
  _fake_home "$home"
  cat >"$home/drivers/docker.sh" <<'FAKE'
[ -n "${_FAKE_DOCKER:-}" ] && return 0
_FAKE_DOCKER=1
driver_up() { :; }
driver_down() { :; }
driver_kubeconfig() { printf ''; }
driver_endpoint() { printf 'fake.local:443'; }
# No driver_installs_rancher, no driver_gate: core must run helm + kubectl gates.
helm_resolve_version() { echo "HELM_RAN" >&2; exit 7; }
FAKE

  run "$home/muster" up --provider docker --out env
  local rc=$status
  rm -rf "$home"
  [ "$rc" -eq 7 ]
}
