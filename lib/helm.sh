#!/usr/bin/env bash
# lib/helm.sh - Rancher channel/version resolution and chart install.
#
# Ports the ansible resolve-helm-version task (which mirrors upstream cypress
# init.sh configure_rancher_helm). The version model has two axes:
#   RANCHER_REPO       a channel key (see MUSTER_REPO_URL below)
#   RANCHER_IMAGE_TAG  "head" or a concrete version like 2.10.1 / 2.10.1-rc3
# The repo key fixes the chart URL and the image registry; the chart version is
# then resolved from `helm search repo --devel --versions` per the tag.
#
# Channel guidance: the alpha and rc channels (rancher-alpha, rancher-latest)
# publish freely pullable staging images and are the intended happy path for
# testing. rancher-prime points at the gated SUSE prime registry and needs
# pull credentials configured out of band; keep it in the matrix but treat it
# as an opt-in, manually configured case rather than a default.
#
# The parsing helpers (version_string, resolve_chart_version, resolve_image_tag)
# are pure: they take their inputs as arguments and touch no cluster, so the
# version matrix is unit-tested without helm or a network.

[ -n "${_MUSTER_HELM_SH:-}" ] && return 0
_MUSTER_HELM_SH=1

# Channel key -> chart repo URL. Single source of truth for the matrix.
declare -gA MUSTER_REPO_URL=(
  ["rancher-prime"]="https://charts.rancher.com/server-charts/prime"
  ["rancher-latest"]="https://charts.optimus.rancher.io/server-charts/latest"
  ["rancher-alpha"]="https://charts.optimus.rancher.io/server-charts/alpha"
  ["rancher-community"]="https://releases.rancher.com/server-charts/stable"
  ["rancher-com-rc"]="https://releases.rancher.com/server-charts/latest"
  ["rancher-com-alpha"]="https://releases.rancher.com/server-charts/alpha"
)

# Channel key -> container image. Empty means "use Docker Hub rancher/rancher
# with the literal tag" (community/com-* lines); a non-empty registry pins a
# staging/prime image and the resolved tag becomes v<chart_version>. The prime
# registry is gated and needs credentials configured separately.
declare -gA MUSTER_REPO_IMAGE=(
  ["rancher-prime"]="registry.suse.com/rancher/rancher"
  ["rancher-latest"]="stgregistry.suse.com/rancher/rancher"
  ["rancher-alpha"]="stgregistry.suse.com/rancher/rancher"
  ["rancher-community"]=""
  ["rancher-com-rc"]=""
  ["rancher-com-alpha"]=""
)

# repo_valid <key> - true if the channel key is known.
repo_valid() { [ -n "${MUSTER_REPO_URL[${1:-}]+x}" ]; }

# repo_keys - print the valid channel keys, space-separated.
repo_keys() { printf '%s ' "${!MUSTER_REPO_URL[@]}"; }

# repo_url <key> / repo_image <key> - map lookups (assume a valid key).
repo_url() { printf '%s' "${MUSTER_REPO_URL[$1]}"; }
repo_image() { printf '%s' "${MUSTER_REPO_IMAGE[$1]}"; }

# version_string <tag> - reduce an image tag to the bare version used to match
# chart versions in `helm search`. Strips a pre-release suffix and an optional
# leading "v": v2.14-head -> 2.14, 2.10.1-rc3 -> 2.10.1, head -> head. Mirrors
# ansible regex_replace('-.*$', '') and additionally drops the leading "v" so
# user tags like "v2.14" match bare chart versions like "2.14.0-rc1".
version_string() {
  local v="${1%%-*}"
  printf '%s' "${v#v}"
}

# resolve_chart_version <repo> <tag> <search_text> - pick the chart version from
# the lines of `helm search repo <repo> --devel --versions`. Pure; prints the
# version (empty if nothing matched). Ported verbatim from the ansible shell.
resolve_chart_version() {
  local repo="$1" tag="$2" search="$3" vs filter
  vs="$(version_string "$tag")"

  if [ "$tag" = "head" ]; then
    printf '%s\n' "$search" | sed -n '1!p' | head -1 \
      | awk '{print $2}' | tr -d '[:space:]'
    return 0
  fi

  case "$repo" in
    rancher-alpha) filter="-alpha" ;;
    rancher-latest) filter="-rc" ;;
    *) filter="" ;;
  esac

  if [ -n "$filter" ]; then
    printf '%s\n' "$search" | grep "^${repo}/rancher[[:space:]]" \
      | grep "$vs" | grep -- "$filter" \
      | awk '{print $2}' | sort -V | tail -1 | tr -d '[:space:]'
  else
    printf '%s\n' "$search" | grep "$vs" \
      | awk '{print $2}' | sort -V | tail -1 | tr -d '[:space:]'
  fi
}

# resolve_image_tag <image> <chart_version> <tag> - the tag handed to helm:
# v<chart_version> when the channel pins an image, else the literal tag.
resolve_image_tag() {
  local image="$1" version="$2" tag="$3"
  if [ -n "$image" ]; then
    printf 'v%s' "$version"
  else
    printf '%s' "$tag"
  fi
}

# helm_resolve_version - orchestrate the impure resolution against a live helm.
# Validates RANCHER_REPO, adds/updates the repo, runs the search, and exports:
#   RANCHER_CHART_URL RANCHER_IMAGE RANCHER_CHART_VERSION RANCHER_IMAGE_TAG_RESOLVED
helm_resolve_version() {
  local repo="${RANCHER_REPO:?RANCHER_REPO is required}"
  local tag="${RANCHER_IMAGE_TAG:?RANCHER_IMAGE_TAG is required}"
  repo_valid "$repo" || die "unknown RANCHER_REPO '$repo' (valid: $(repo_keys))"

  RANCHER_CHART_URL="$(repo_url "$repo")"
  RANCHER_IMAGE="$(repo_image "$repo")"

  require_cmd helm
  retry 3 5 "helm repo add $repo" -- \
    helm repo add "$repo" "$RANCHER_CHART_URL" --force-update
  retry 3 5 "helm repo update" -- helm repo update "$repo"

  local search
  search="$(helm search repo "$repo" --devel --versions 2>/dev/null || true)"
  RANCHER_CHART_VERSION="$(resolve_chart_version "$repo" "$tag" "$search" || true)"
  [ -n "$RANCHER_CHART_VERSION" ] \
    || die "could not resolve a chart version for repo=$repo tag=$tag"

  RANCHER_IMAGE_TAG_RESOLVED="$(resolve_image_tag "$RANCHER_IMAGE" "$RANCHER_CHART_VERSION" "$tag")"
  export RANCHER_CHART_URL RANCHER_IMAGE RANCHER_CHART_VERSION RANCHER_IMAGE_TAG_RESOLVED
  log_info "resolved: repo=$repo chart=$RANCHER_CHART_VERSION image=${RANCHER_IMAGE:-rancher/rancher} tag=$RANCHER_IMAGE_TAG_RESOLVED"
}

# helm_install_rancher - cert-manager + rancher install. Wired in the Phase 1
# driver step; the resolution above is complete and unit-tested.
helm_install_rancher() { die "helm_install_rancher: not implemented (Phase 1 driver wiring)"; }
