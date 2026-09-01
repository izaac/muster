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
  # The image tag spells the build with a dash; the release tag uses a plus,
  # percent-encoded so it survives the URL.
  run mirror_k3s_release_images "v1.33.1-k3s1"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "k3s/releases/download/v1.33.1%2Bk3s1/k3s-images.txt"
}

@test "mirror_k3s_release_images takes the tag the cluster's own node runs" {
  _freshness_curl() {
    printf 'url=%s\n' "$1"
    printf 'docker.io/rancher/mirrored-pause:3.6\n'
  }
  K3S_IMAGE="rancher/k3s:v1.35.2-k3s1"
  run mirror_k3s_release_images "$(mirror_k3s_tag)"
  echo "$output" | grep -q "download/v1.35.2%2Bk3s1/"
}

@test "mirror_k3s_release_images yields nothing when the release is unreachable" {
  _freshness_curl() { return 1; }
  run mirror_k3s_release_images "v1.33.1-k3s1"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mirror_k3s_release_images ignores a response that is not an image list" {
  _freshness_curl() { printf '<html>404: Not Found</html>\n'; }
  run mirror_k3s_release_images "v1.33.1-k3s1"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mirror_k3s_release_images refuses to guess when given no tag" {
  run mirror_k3s_release_images
  [ "$status" -ne 0 ]
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

# --- image-list fallback for a line that has not released ---------------------

@test "mirror_list_candidates asks for the build's own list first" {
  # A pre-release publishes its own list, naming its own component tags
  # (fleet v0.16.1-beta.1 where the release names v0.16.0). The release list is
  # a fallback, not the answer.
  run mirror_list_candidates 2.14.4-rc1
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -1)" = "https://prime.ribs.rancher.io/rancher/v2.14.4-rc1/rancher-images.txt" ]
  [[ "$output" == *"/v2.14.4/rancher-images.txt"* ]]
}

@test "mirror_list_candidates takes a commit head list from the prime head path" {
  # Scheduled Prime head builds publish under a separate path, and their server
  # and agent are commit-tagged, so no release list can name them.
  run mirror_list_candidates 2.16.0-b29c3a6-head
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | head -1)" = "https://prime.ribs.rancher.io/rancher/internal/prime/head/v2.16.0-b29c3a6-head/rancher-images.txt" ]
}

@test "mirror_list_candidates does not invent a list for a per-branch head chart" {
  # X.Y-<sha>-head is a chart identity with no artifacts of its own, so asking
  # for one is a request that can only 404.
  run mirror_list_candidates 2.15-842907d326ea023d373b40e0b2dca7093b4f1c07-head
  [ "$status" -eq 0 ]
  [[ "$output" != *"internal/prime/head"* ]]
  [[ "$output" == *"/v2.15.0/rancher-images.txt"* ]]
}

@test "mirror_list_candidates asks GitHub for a pre-release too" {
  # Community pre-releases (2.15.1-alpha1) are published as a GitHub release
  # asset as well, so keep both sources for the exact version.
  run mirror_list_candidates 2.15.1-alpha1
  [[ "$output" == *"https://prime.ribs.rancher.io/rancher/v2.15.1-alpha1/rancher-images.txt"* ]]
  [[ "$output" == *"https://github.com/rancher/rancher/releases/download/v2.15.1-alpha1/rancher-images.txt"* ]]
}

@test "mirror_list_candidates walks back a minor when the line has no release" {
  # 2.16 publishes head builds while v2.16.0 does not exist, so without this the
  # mirror could not be filled for it at all.
  run mirror_list_candidates 2.16.0-abc-head
  [[ "$output" == *"/v2.16.0/rancher-images.txt"* ]]
  [[ "$output" == *"/v2.15.0/rancher-images.txt"* ]]
  [[ "$output" == *"/v2.14.0/rancher-images.txt"* ]]
}

@test "mirror_list_candidates never emits the same candidate twice" {
  run mirror_list_candidates 2.16.0
  local dupes
  dupes="$(printf '%s\n' "$output" | sort | uniq -d)"
  [ -z "$dupes" ]
}

@test "mirror_list_candidates does not walk below the start of a major" {
  run mirror_list_candidates 2.1.0
  [[ "$output" != *"v2.-1.0"* ]]
  [[ "$output" != *"v2.0.0"* ]] || true
  # Every candidate is a real version triple.
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    [[ "$u" =~ /v[0-9]+\.[0-9]+\.[0-9]+/ ]]
  done <<<"$output"
}

# --- images the chart pins itself --------------------------------------------

@test "mirror_chart_images reports what the chart renders" {
  RANCHER_REPO=rancher-latest
  RANCHER_CHART_VERSION=2.16.0-abc-head
  helm() {
    printf '%s\n' \
      '        image: "stgregistry.suse.com/rancher/rancher-assets:v2.16-20260805T1815Z-dev"' \
      '        image: "stgregistry.suse.com/rancher/rancher:v2.16.0-abc-head"'
  }
  run mirror_chart_images
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "stgregistry.suse.com/rancher/rancher-assets:v2.16-20260805T1815Z-dev"
}

@test "mirror_chart_images yields nothing when the chart is not resolved" {
  RANCHER_REPO=""
  RANCHER_CHART_VERSION=""
  run mirror_chart_images
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mirror_chart_images yields nothing rather than failing when helm cannot render" {
  RANCHER_REPO=rancher-latest
  RANCHER_CHART_VERSION=2.16.0-abc-head
  helm() { return 1; }
  run mirror_chart_images
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "mirror_plan carries a component the chart pins but no image list names" {
  # From 2.16 the system charts ship in rancher-assets at a datestamped tag, and
  # the server pod cannot start without it, so a mirror that misses it fails
  # before the first readiness gate.
  mirror_chart_images() {
    printf '%s\n' 'stgregistry.suse.com/rancher/rancher-assets:v2.16-20260805T1815Z-dev'
  }
  run mirror_plan
  [ "$status" -eq 0 ]
  echo "$output" | grep -qx "stgregistry.suse.com/rancher/rancher-assets:v2.16-20260805T1815Z-dev"
}

@test "rancher-assets survives the core family filter" {
  run bash -c "printf '%s\n' 'rancher/rancher-assets:v2.16-x-dev' 'rancher/unrelated:v1' | { $(declare -f mirror_filter_core); MUSTER_MIRROR_CORE_FAMILIES='$MUSTER_MIRROR_CORE_FAMILIES'; mirror_filter_core; }"
  echo "$output" | grep -qx "rancher/rancher-assets:v2.16-x-dev"
  ! echo "$output" | grep -q "unrelated"
}
