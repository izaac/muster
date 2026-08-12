#!/usr/bin/env bats
# Unit tests for the mirror plan additions: the agent at the resolved server tag
# and the cert-manager OCI chart. Pure: the two impure inputs (image list and
# cert-manager image render) are stubbed, so the plan is computed offline.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  . "$ROOT/lib/util.sh"
  # shellcheck source=../lib/helm.sh
  . "$ROOT/lib/helm.sh"
  # shellcheck source=../lib/mirror.sh
  . "$ROOT/lib/mirror.sh"

  # The list a release publishes: note the agent is named only at its GA tag.
  mirror_fetch_list() {
    printf '%s\n' \
      'rancher/rancher:v2.14.4' \
      'rancher/rancher-agent:v2.14.4' \
      'rancher/shell:v0.4.1' \
      'rancher/fleet:v0.14.0' \
      'rancher/mirrored-coredns-coredns:1.12.0' \
      'rancher/hardened-kubernetes:v1.33.1'
  }
  mirror_cert_manager_images() { printf '%s\n' 'quay.io/jetstack/cert-manager-controller:v1.19.4'; }

  RANCHER_IMAGE="stgregistry.suse.com/rancher/rancher"
  RANCHER_IMAGE_TAG_RESOLVED="v2.14.4-rc1"
  RANCHER_CHART_VERSION="2.14.4-rc1"
  CERT_MANAGER_VERSION="v1.19.4"
  unset MIRROR_ALL MIRROR_EXTENSION
}

@test "mirror_plan mirrors the server at the resolved tag" {
  run mirror_plan
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "stgregistry.suse.com/rancher/rancher:v2.14.4-rc1"
}

@test "mirror_plan mirrors the agent at the resolved server tag, not the list GA tag" {
  run mirror_plan
  echo "$output" | grep -qx "stgregistry.suse.com/rancher/rancher-agent:v2.14.4-rc1"
}

@test "a community server yields a docker.io-style agent path at the resolved tag" {
  RANCHER_IMAGE="rancher/rancher"
  run mirror_plan
  echo "$output" | grep -qx "rancher/rancher-agent:v2.14.4-rc1"
}

@test "mirror_plan mirrors the cert-manager OCI chart at the bare version" {
  run mirror_plan
  echo "$output" | grep -qx "quay.io/jetstack/charts/cert-manager:1.19.4"
}

@test "mirror_plan keeps core families and drops unknown ones by default" {
  run mirror_plan
  echo "$output" | grep -q "rancher/mirrored-coredns-coredns:1.12.0"
  ! echo "$output" | grep -q "rancher/hardened-kubernetes"
}
