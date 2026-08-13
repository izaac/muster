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

# --- the k3s release image list ---------------------------------------------
#
# The images a node's own k3s starts belong to k3s, not to Rancher. A Rancher
# release list names most of them, but at the tags Rancher's bundled k3s uses,
# which is not the version the node runs, so they come from the k3s release.

@test "mirror_k3s_release_images turns an image tag into the k3s release URL" {
  _freshness_curl() {
    printf 'url=%s\n' "$1"
    printf 'docker.io/rancher/mirrored-pause:3.6\n'
  }
  K3S_IMAGE="rancher/k3s:v1.33.1-k3s1"
  run mirror_k3s_release_images
  [ "$status" -eq 0 ]
  # The image tag spells the build with a dash; the release tag uses a plus,
  # percent-encoded so it survives the URL.
  echo "$output" | grep -q "k3s/releases/download/v1.33.1%2Bk3s1/k3s-images.txt"
}

@test "mirror_k3s_release_images takes the version from an explicit argument" {
  _freshness_curl() {
    printf 'url=%s\n' "$1"
    printf 'docker.io/rancher/mirrored-pause:3.6\n'
  }
  run mirror_k3s_release_images "v1.35.2-k3s1"
  echo "$output" | grep -q "download/v1.35.2%2Bk3s1/"
}

@test "mirror_k3s_release_images yields nothing when the release is unreachable" {
  _freshness_curl() { return 1; }
  K3S_IMAGE="rancher/k3s:v1.33.1-k3s1"
  run mirror_k3s_release_images
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mirror_k3s_release_images ignores a response that is not an image list" {
  _freshness_curl() { printf '<html>404: Not Found</html>\n'; }
  K3S_IMAGE="rancher/k3s:v1.33.1-k3s1"
  run mirror_k3s_release_images
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mirror_plan carries the k3s node images at the node's own tags" {
  mirror_k3s_release_images() {
    printf '%s\n' \
      'docker.io/rancher/mirrored-coredns-coredns:1.12.1' \
      'docker.io/rancher/mirrored-library-traefik:3.3.6' \
      'docker.io/rancher/klipper-lb:v0.4.13'
  }
  run mirror_plan
  [ "$status" -eq 0 ]
  # The node runs 1.12.1; the Rancher list names 1.12.0. Both are mirrored, and
  # the one the node asks for is the one that would otherwise 404.
  echo "$output" | grep -qx "docker.io/rancher/mirrored-coredns-coredns:1.12.1"
  echo "$output" | grep -qx "docker.io/rancher/klipper-lb:v0.4.13"
}

@test "mirror_plan survives a k3s release list that could not be fetched" {
  mirror_k3s_release_images() { return 0; }
  run mirror_plan
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "stgregistry.suse.com/rancher/rancher:v2.14.4-rc1"
}

# --- reading images off a running cluster ------------------------------------

@test "mirror_cluster_images strips the mirror prefix so entries are upstream paths" {
  kubectl() { printf '%s\n' 'muster-registry-e2e:5000/rancher/fleet:v0.16.1-beta.1' 'rancher/shell:v0.8.1'; }
  run mirror_cluster_images /tmp/kc muster-registry-e2e:5000
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "rancher/fleet:v0.16.1-beta.1"
  echo "$output" | grep -qx "rancher/shell:v0.8.1"
}

@test "mirror_cluster_images says the cluster is unreachable instead of dying on a pipe" {
  kubectl() { return 1; }
  run mirror_cluster_images /tmp/kc muster-registry-e2e:5000
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs a reachable cluster"* ]]
}

# --- healing a mirror gap mid-gate -------------------------------------------
#
# A prerelease server installs system charts naming component versions that no
# published list carries and the chart does not know. The cluster is the only
# thing that knows, and it says so by failing to pull an image it names.

@test "mirror_failing_images reports only images that are actually failing" {
  kubectl() {
    printf '%s\n' \
      'Running muster-registry-e2e:5000/rancher/rancher:v2.15.1-alpha1' \
      'ImagePullBackOff muster-registry-e2e:5000/rancher/fleet:v0.16.1-beta.1' \
      'ErrImagePull muster-registry-e2e:5000/rancher/rancher-webhook:v0.11.1-rc.1'
  }
  run mirror_failing_images /tmp/kc muster-registry-e2e:5000
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "rancher/fleet:v0.16.1-beta.1"
  echo "$output" | grep -qx "rancher/rancher-webhook:v0.11.1-rc.1"
  ! echo "$output" | grep -q "rancher/rancher:v2.15.1-alpha1"
}

@test "mirror_failing_images is empty when nothing is stuck" {
  kubectl() { printf 'Running muster-registry-e2e:5000/rancher/rancher:v2.15.1-alpha1\n'; }
  run mirror_failing_images /tmp/kc muster-registry-e2e:5000
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mirror_heal_pulls copies what is missing and reports that it repaired something" {
  INSTANCE=e2e
  MIRROR_INSECURE=true
  mirror_failing_images() { printf 'rancher/fleet:v0.16.1-beta.1\n'; }
  mirror_copy() {
    printf 'copied %s -> %s\n' "$1" "$2"
    return 0
  }
  kubectl() { return 0; }
  run mirror_heal_pulls /tmp/kc localhost:5000
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "copied rancher/fleet:v0.16.1-beta.1 -> localhost:5000/rancher/fleet:v0.16.1-beta.1"
}

@test "mirror_heal_pulls is false when there is nothing to repair, so a gate keeps waiting" {
  mirror_failing_images() { printf ''; }
  run mirror_heal_pulls /tmp/kc localhost:5000
  [ "$status" -ne 0 ]
}

@test "mirror_heal_pulls is false when the missing image cannot be copied either" {
  INSTANCE=e2e
  mirror_failing_images() { printf 'rancher/nope:v1\n'; }
  mirror_copy() { return 1; }
  run mirror_heal_pulls /tmp/kc localhost:5000
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not be copied"* ]]
}
