#!/usr/bin/env bash
# lib/mirror.sh - populate a private registry for an airgapped install.
#
# Rancher publishes a per-release rancher-images.txt listing every image an
# install can need. The documented flow saves those to a tarball and loads them
# on the far side; copying registry to registry with skopeo reaches the same
# place without the intermediate file or a docker daemon, which is what we want
# when the "airgap" is a local network.
#
# Two things the published list does not cover and that are added here:
# cert-manager, which Rancher requires but does not ship, and the K3K images the
# virtual-clusters extension needs to actually provision anything.
#
# The list is a set of bare "rancher/<name>:<tag>" lines. Where those are pulled
# from is a separate decision: the same names exist on Docker Hub, on
# registry.suse.com and on registry.rancher.com, and only the prime registries
# carry builds that report themselves as Prime.

[ -n "${_MUSTER_MIRROR_SH:-}" ] && return 0
_MUSTER_MIRROR_SH=1

# What the default mirror covers: a Rancher server that serves its UI, and enough
# to provision a k3s downstream cluster from that UI. Family names only, so the
# tags come from the release's own image list and nothing here pins a version.
#
# Left out: RKE2, the cloud operators (EKS/AKS/GKE), Harvester, monitoring,
# NeuVector and the CAPI providers. Use --mirror-all when any of those matter.

# The server and the local cluster it runs. Rancher installs these itself on
# first start, so a missing one is not an install failure but a controller that
# never becomes ready.
MUSTER_MIRROR_SERVER_FAMILIES="rancher rancher-agent shell rancher-webhook fleet fleet-agent gitjob helmop system-agent system-upgrade-controller kuberlr-kubectl ui-plugin-catalog remotedialer-proxy scc-operator turtles cluster-api-controller kubectl"

# Provisioning a k3s cluster: the installer image system-agent fetches, the node
# driver, and the images k3s itself starts on a new node.
MUSTER_MIRROR_K3S_FAMILIES="system-agent-installer-k3s k3s-upgrade klipper-helm klipper-lb local-path-provisioner machine mirrored-coredns-coredns mirrored-library-busybox mirrored-library-traefik mirrored-metrics-server mirrored-pause"

MUSTER_MIRROR_CORE_FAMILIES="${MUSTER_MIRROR_SERVER_FAMILIES} ${MUSTER_MIRROR_K3S_FAMILIES}"

# K3K provisions the virtual clusters the extension drives. Not in any Rancher
# image list, because it is not part of Rancher.
MUSTER_MIRROR_EXTENSION_IMAGES="rancher/k3k rancher/k3k-kubelet"

# mirror_list_candidates <chart_version> - image-list URLs to try, best first.
#
# A pre-release has no list of its own, so fall back to the release it is built
# from and then to that line's first release. The list only supplies supporting
# images; the server image is mirrored separately from what actually resolved.
mirror_list_candidates() {
  local v="${1:?chart version required}" base minor
  base="${v%%-*}"
  minor="$(printf '%s' "$base" | cut -d. -f1,2)"
  local ver
  for ver in "$base" "${minor}.0"; do
    printf 'https://prime.ribs.rancher.io/rancher/v%s/rancher-images.txt\n' "$ver"
    printf 'https://github.com/rancher/rancher/releases/download/v%s/rancher-images.txt\n' "$ver"
  done
}

# mirror_fetch_list <chart_version> - the first image list that resolves, on
# stdout. Prints the URL it used to stderr.
mirror_fetch_list() {
  local v="${1:?chart version required}" url body
  while read -r url; do
    body="$(_freshness_curl "$url" || true)"
    case "$body" in
      *rancher/*)
        log_info "image list: $url"
        printf '%s\n' "$body"
        return 0
        ;;
    esac
  done < <(mirror_list_candidates "$v")
  return 1
}

# mirror_filter_core - keep only the core families, reading a list on stdin.
mirror_filter_core() {
  local pattern
  pattern="^rancher/($(printf '%s' "$MUSTER_MIRROR_CORE_FAMILIES" | tr ' ' '|')):"
  grep -E "$pattern" || true
}

# mirror_cert_manager_images <version> - the cert-manager images for a version.
# Rendering the chart is what the Rancher docs tell you to do, and it means the
# set follows whatever that release actually references.
mirror_cert_manager_images() {
  local ver="${1:?cert-manager version required}"
  command -v helm >/dev/null 2>&1 || return 0
  helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null 2>&1 || return 0
  helm repo update jetstack >/dev/null 2>&1 || true
  helm template cert-manager jetstack/cert-manager --version "$ver" \
    --set installCRDs=true 2>/dev/null \
    | grep -oE 'image: *"?[^"]*' | sed 's/image: *"*//' | sort -u
}

# mirror_source_ref <image_ref> <source_registry> - where to pull a bare
# "rancher/x:tag" entry from. An entry that already names a registry is left
# alone, so the extension and cert-manager images keep their own homes.
mirror_source_ref() {
  local ref="${1:?ref required}" src="${2:-}"
  case "${ref%%/*}" in
    localhost | *.* | *:*) printf '%s' "$ref" ;;
    *) printf '%s' "${src:+${src}/}${ref}" ;;
  esac
}

# mirror_dest_ref <image_ref> <registry> - the same image under the target
# registry, keeping its repository path so systemDefaultRegistry resolves it.
# Rancher builds <systemDefaultRegistry>/<repository>:<tag>, so "rancher/shell"
# must stay "rancher/shell" under the new host.
mirror_dest_ref() {
  local ref="${1:?ref required}" reg="${2:?registry required}"
  local path="$ref"
  case "${ref%%/*}" in
    localhost | *.* | *:*) path="${ref#*/}" ;;
  esac
  printf '%s/%s' "$reg" "$path"
}

# mirror_copy <source> <dest> [insecure] - copy one image, skipping work that is
# already done so a re-run after a failure is cheap.
mirror_copy() {
  local src="${1:?source required}" dst="${2:?dest required}" insecure="${3:-}"
  local -a args=(--retry-times 3)
  if is_true "$insecure"; then
    args+=(--dest-tls-verify=false)
  fi
  if skopeo inspect --raw ${insecure:+--tls-verify=false} "docker://${dst}" >/dev/null 2>&1; then
    return 0
  fi
  skopeo copy "${args[@]}" "docker://${src}" "docker://${dst}" >/dev/null 2>&1
}

# mirror_plan - the images to copy, one per line, on stdout.
#
# The server image is taken from what actually resolved rather than from the
# list, because the two can legitimately differ: a Prime prerelease has no image
# list of its own, so the supporting images come from the nearest release while
# the server image is the prerelease itself.
mirror_plan() {
  local list core
  list="$(mirror_fetch_list "$RANCHER_CHART_VERSION")" \
    || die "no image list found for chart $RANCHER_CHART_VERSION"

  if is_true "${MIRROR_ALL:-}"; then
    core="$list"
  else
    core="$(printf '%s\n' "$list" | mirror_filter_core)"
  fi

  {
    printf '%s:%s\n' "${RANCHER_IMAGE:-rancher/rancher}" "$RANCHER_IMAGE_TAG_RESOLVED"
    printf '%s\n' "$core"
    mirror_cert_manager_images "${CERT_MANAGER_VERSION:-$CERT_MANAGER_VERSION_DEFAULT}"
    if is_true "${MIRROR_EXTENSION:-}"; then
      local img tag
      tag="$(mirror_k3k_tag)"
      for img in $MUSTER_MIRROR_EXTENSION_IMAGES; do
        printf '%s:%s\n' "$img" "$tag"
      done
      # K3K starts a k3s server for every virtual cluster it creates. That image
      # is in no Rancher image list, because k3s is not a Rancher component.
      printf 'rancher/k3s:%s\n' "$(mirror_k3s_tag)"
      local v
      while read -r v; do
        [ -n "$v" ] && printf 'rancher/k3s:%s\n' "$v"
      done < <(mirror_k3s_offered_tags "${MIRROR_K3S_VERSIONS:-3}")
    fi
  } | sed '/^[[:space:]]*$/d' | sort -u
}

# mirror_cluster_images <kubeconfig> <registry> - images a running cluster asks
# for that the mirror does not have, on stdout.
#
# The published image list belongs to a release, and a prerelease server ships
# newer components than the release it is built from: a 2.15.1-alpha1 server
# wants fleet v0.16.1-beta.1 where the 2.15.0 list names v0.16.0. No list can
# be right about that, but the cluster itself knows exactly what it is asking
# for, so ask it and mirror the difference.
mirror_cluster_images() {
  local kc="${1:?kubeconfig required}" reg="${2:?registry required}"
  kubectl --kubeconfig "$kc" get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{range .spec.initContainers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
    | sed "s|^${reg}/||" \
    | sed '/^$/d' | sort -u
}

# mirror_k3k_tag - newest K3K release, or a pinned MIRROR_K3K_TAG. K3K versions
# independently of Rancher, so ask its repository rather than assume.
mirror_k3k_tag() {
  if [ -n "${MIRROR_K3K_TAG:-}" ]; then
    printf '%s' "$MIRROR_K3K_TAG"
    return 0
  fi
  local tag
  tag="$(image_newest_ga docker.io/rancher/k3k)"
  printf 'v%s' "${tag:-1.1.0}"
}

# mirror_k3s_offered_tags [count] - the newest k3s images, as the extension's
# version dropdown lists them.
#
# K3K is told "rancher/k3s" with no tag and appends the version the virtual
# cluster asks for, so whichever entry the operator picks in the UI is the tag
# that gets pulled. There is no way to know that in advance, so mirror the
# newest few and let MIRROR_K3S_VERSIONS widen it.
mirror_k3s_offered_tags() {
  local count="${1:-3}"
  command -v skopeo >/dev/null 2>&1 || return 0
  skopeo list-tags docker://docker.io/rancher/k3s 2>/dev/null \
    | sed -n 's/.*"\(.*\)".*/\1/p' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+-k3s[0-9]+$' \
    | sort -V | tail -"$count"
}

# mirror_k3s_tag - the k3s version K3K should start for a virtual cluster.
# Defaults to the node image the cluster itself runs, so the virtual clusters
# match their host, and falls back to the dashboard team's pin.
mirror_k3s_tag() {
  if [ -n "${MIRROR_K3S_TAG:-}" ]; then
    printf '%s' "$MIRROR_K3S_TAG"
    return 0
  fi
  local img="${K3S_IMAGE:-}"
  [ -n "$img" ] || img="$(branches_k3s_image "${RANCHER_IMAGE_TAG:-head}")"
  case "$img" in
    *:*) printf '%s' "${img##*:}" ;;
    *) printf 'v1.33.1-k3s1' ;;
  esac
}

# mirror_run <registry> - copy everything the plan names into the registry.
#
# With MIRROR_FROM_CLUSTER set, the plan is instead whatever a running cluster
# is asking for. That covers the components a prerelease server pulls in that no
# published list names.
mirror_run() {
  local reg="${1:?registry required}" insecure="${MIRROR_INSECURE:-}"
  require_cmd skopeo

  local plan total=0 done_n=0 failed=0 ref src dst
  if is_true "${MIRROR_FROM_CLUSTER:-}"; then
    local kc
    kc="$(driver_kubeconfig)"
    local node_reg
    node_reg="$(airgap_registry_host "$reg")"
    plan="$(mirror_cluster_images "$kc" "$node_reg")"
    log_info "filling gaps from the running cluster"
  else
    helm_resolve_version
    plan="$(mirror_plan)"
  fi
  total="$(printf '%s\n' "$plan" | wc -l | tr -d ' ')"

  log_info "mirroring $total images to ${reg}"
  while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    src="$(mirror_source_ref "$ref" "${MIRROR_SOURCE_REGISTRY:-}")"
    dst="$(mirror_dest_ref "$ref" "$reg")"
    if mirror_copy "$src" "$dst" "$insecure"; then
      done_n=$((done_n + 1))
      printf '\r  %d/%d %-60.60s' "$done_n" "$total" "$ref" >&2
    else
      failed=$((failed + 1))
      printf '\r%-72s\r' '' >&2
      log_warn "could not copy $src"
    fi
  done <<<"$plan"
  printf '\r%-72s\r' '' >&2

  log_ok "mirrored ${done_n}/${total} images"
  [ "$failed" -gt 0 ] && log_warn "${failed} image(s) could not be copied"

  # The server image is the one thing that must be right, so prove it landed and
  # report the flavour: a mirror that quietly holds a community build would fail
  # much later, when a Prime-only extension refuses to load.
  is_true "${MIRROR_FROM_CLUSTER:-}" && return 0

  local server_dst flavour
  server_dst="$(mirror_dest_ref "${RANCHER_IMAGE:-rancher/rancher}:${RANCHER_IMAGE_TAG_RESOLVED}" "$reg")"
  flavour="$(MUSTER_REGISTRY_INSECURE="$insecure" image_prime_flavour "${server_dst%:*}" "${server_dst##*:}")"
  log_info "server image in mirror: ${server_dst} (${flavour})"
  [ "$flavour" = missing ] && die "the server image did not reach the mirror"

  log_info "install with --set systemDefaultRegistry=${reg}"
  return 0
}
