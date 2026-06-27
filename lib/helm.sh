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

# Default cert-manager version and the SHA256 of its release CRD manifest,
# pinned in source for a deterministic, reviewable supply chain. GitHub only
# backfills release-asset digests for recent uploads, so older cert-manager
# tags (e.g. v1.16.x) report "digest": null; a source pin is the strongest and
# most reproducible stance. For a version not pinned here, set
# CERT_MANAGER_CRDS_SHA256 explicitly, or rely on the GitHub asset digest when
# the upstream release carries one.
CERT_MANAGER_VERSION_DEFAULT="v1.16.2"
declare -gA MUSTER_CERT_MANAGER_CRDS_SHA256=(
  ["v1.16.2"]="0555ce0be71aeedd59aa7e6c12e557f44b8df133634bfc5f2cf976b5887e1198"
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
# version (empty if nothing matched). Based on the ansible shell, but the head
# path uses `sort -V` instead of trusting helm's order: helm sorts pre-release
# identifiers lexically, so 2.x-alpha9 ranks above 2.x-alpha14 ('9' > '1') and a
# plain `head -1` would pick a stale alpha. Version sort gives the true newest.
resolve_chart_version() {
  local repo="$1" tag="$2" search="$3" vs filter
  vs="$(version_string "$tag")"

  if [ "$tag" = "head" ]; then
    printf '%s\n' "$search" | sed -n '1!p' \
      | awk '{print $2}' | sort -V | tail -1 | tr -d '[:space:]'
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

# helm_install_rancher <kubeconfig> <hostname> - install cert-manager and
# Rancher. Assumes helm_resolve_version has run (RANCHER_* exported and the
# Rancher chart repo added). The cert-manager CRD manifest is SHA256-verified
# before it is applied; its checksum comes from the GitHub release asset digest
# unless CERT_MANAGER_CRDS_SHA256 pins it inline.
helm_install_rancher() {
  local kc="${1:?kubeconfig path required}" host="${2:?hostname required}"
  local cmver="${CERT_MANAGER_VERSION:-$CERT_MANAGER_VERSION_DEFAULT}"
  local pin="${CERT_MANAGER_CRDS_SHA256:-${MUSTER_CERT_MANAGER_CRDS_SHA256[$cmver]:-}}"
  require_cmd kubectl
  require_cmd helm

  local crds
  crds="$(mktemp)"
  local crds_url="https://github.com/cert-manager/cert-manager/releases/download/${cmver}/cert-manager.crds.yaml"
  if [ -n "$pin" ]; then
    DV_URL="$crds_url" DV_DEST="$crds" DV_FORMAT="inline" \
      DV_SHA256="$pin" download_verify >/dev/null
  else
    DV_URL="$crds_url" DV_DEST="$crds" DV_FORMAT="github_release" \
      DV_GITHUB_REPO="cert-manager/cert-manager" DV_GITHUB_TAG="$cmver" \
      DV_ARTIFACT_NAME="cert-manager.crds.yaml" download_verify >/dev/null
  fi

  log_info "cert-manager $cmver (verified CRDs)"
  kubectl --kubeconfig "$kc" apply -f "$crds"
  rm -f "$crds"
  retry 3 5 "helm repo add jetstack" -- \
    helm --kubeconfig "$kc" repo add jetstack https://charts.jetstack.io --force-update
  helm --kubeconfig "$kc" upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager --create-namespace \
    --version "$cmver" --wait --timeout 5m
  kubectl --kubeconfig "$kc" -n cert-manager rollout status \
    deploy/cert-manager-webhook --timeout=180s

  local image="${RANCHER_IMAGE:-rancher/rancher}"
  local agent_image="${image%/*}/rancher-agent"
  local tag="$RANCHER_IMAGE_TAG_RESOLVED"
  log_info "rancher chart $RANCHER_CHART_VERSION (image ${image}:${tag})"
  local args=(
    upgrade --install rancher "${RANCHER_REPO}/rancher"
    --devel --version "$RANCHER_CHART_VERSION"
    --namespace cattle-system --create-namespace
    --set "hostname=${host}"
    --set "replicas=1"
    --set "rancherImage=${image}"
    --set "rancherImageTag=${tag}"
    --set "rancherImagePullPolicy=Always"
    --set "bootstrapPassword=${RANCHER_PASSWORD:-password1234}"
    --set "ingress.ingressClassName=traefik"
    --set "extraEnv[0].name=CATTLE_AGENT_IMAGE"
    --set-string "extraEnv[0].value=${agent_image}:${tag}"
  )
  if [ -n "${DASHBOARD_DIST:-}" ]; then
    args+=(
      --set "extraEnv[1].name=CATTLE_UI_OFFLINE_PREFERRED"
      --set-string "extraEnv[1].value=true"
    )
  fi
  helm --kubeconfig "$kc" "${args[@]}"

  if [ -n "${DASHBOARD_DIST:-}" ]; then
    log_info "hostPath-mounting dashboard dist over the pod UI"
    kubectl --kubeconfig "$kc" -n cattle-system patch deploy rancher \
      --type=strategic -p '{
      "spec": {"template": {"spec": {
        "volumes": [{"name": "dashboard-dist", "hostPath": {"path": "/dashboard-dist", "type": "Directory"}}],
        "containers": [{"name": "rancher", "volumeMounts": [{"name": "dashboard-dist", "mountPath": "/usr/share/rancher/ui-dashboard/dashboard"}]}]
      }}}
    }'
  fi
}
