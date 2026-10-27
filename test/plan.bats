#!/usr/bin/env bats
# Unit tests for the --dry-run plan report's HA topology row.
#
# Resolution and the image/UI probes are stubbed: the question here is whether
# the plan says what topology a run would create.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  . "$ROOT/lib/util.sh"
  # shellcheck source=../lib/helm.sh
  . "$ROOT/lib/helm.sh"
  # shellcheck source=../lib/ui.sh
  . "$ROOT/lib/ui.sh"
  # shellcheck source=../lib/plan.sh
  . "$ROOT/lib/plan.sh"

  PROVIDER="existing"
  INSTANCE="e2e"
  EXTERNAL="false"
  DASHBOARD_DIST=""
  unset RANCHER_REPLICAS K3D_SERVERS RANCHER_CHART_RELEASED DASHBOARD_BRANCH_RESOLVED METADATA_REGISTRY

  helm_resolve_version() {
    RANCHER_IMAGE=rancher/rancher
    RANCHER_REPO=rancher-com-rc
    RANCHER_CHART_URL=https://releases.rancher.com/server-charts/latest
    RANCHER_CHART_VERSION=2.13.3
    RANCHER_IMAGE_TAG_RESOLVED=v2.13.3
  }
  image_prime_flavour() { printf 'community'; }
  ui_source() { printf 'image'; }
  helm_missing_tag_hint() { :; }
}

@test "the plan shows the HA topology when replicas or servers exceed one" {
  RANCHER_REPLICAS=3 K3D_SERVERS=3
  run plan_report
  [ "$status" -eq 0 ]
  [[ "$output" == *"topology"* ]]
  [[ "$output" == *"replicas 3  (servers: 3)"* ]]
}

@test "a server count above one is shown even with one replica" {
  RANCHER_REPLICAS=1 K3D_SERVERS=3
  run plan_report
  [[ "$output" == *"replicas 1  (servers: 3)"* ]]
}

@test "the default single-node plan stays quiet" {
  run plan_report
  [ "$status" -eq 0 ]
  [[ "$output" != *"topology"* ]]
}
