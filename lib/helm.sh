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
  ["rancher-prime-ga"]="https://charts.rancher.com/server-charts/prime"
  ["rancher-latest"]="https://charts.optimus.rancher.io/server-charts/latest"
  ["rancher-alpha"]="https://charts.optimus.rancher.io/server-charts/alpha"
  ["rancher-community"]="https://releases.rancher.com/server-charts/stable"
  ["rancher-com-rc"]="https://releases.rancher.com/server-charts/latest"
  ["rancher-com-alpha"]="https://releases.rancher.com/server-charts/alpha"
)

# Channel key -> container image. Empty means "use Docker Hub rancher/rancher
# with the literal tag" (community/com-* lines); a non-empty registry pins a
# staging/prime image and the resolved tag becomes v<chart_version>.
#
# Whether a build reports itself as Prime, which is what gates Prime-only UI
# extensions, is a property of the image and not of the channel: some tags on a
# prime registry are community builds. Use `muster up --dry-run` to read it off
# the image that a given set of flags actually resolves to.
#   rancher-prime-ga  registry.rancher.com, GA releases, anonymously pullable
#   rancher-prime     registry.suse.com, gated, needs credentials out of band
declare -gA MUSTER_REPO_IMAGE=(
  ["rancher-prime"]="registry.suse.com/rancher/rancher"
  ["rancher-prime-ga"]="registry.rancher.com/rancher/rancher"
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
CERT_MANAGER_VERSION_DEFAULT="v1.19.4"
declare -gA MUSTER_CERT_MANAGER_CRDS_SHA256=(
  ["v1.16.2"]="0555ce0be71aeedd59aa7e6c12e557f44b8df133634bfc5f2cf976b5887e1198"
  ["v1.19.4"]="0e09c26d64fbdb56f2ea95b5b2350991980a184a9ce9a09d3a9a207594ce38b0"
)

# repo_valid <key> - true if the channel key is known.
repo_valid() { [ -n "${MUSTER_REPO_URL[${1:-}]+x}" ]; }

# repo_keys - print the valid channel keys, space-separated.
repo_keys() { printf '%s\n' "${!MUSTER_REPO_URL[@]}" | sort | tr '\n' ' '; }

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

  # `helm search repo <name>` is a keyword search over every configured
  # repository, not a listing of one. Both staging repos publish a chart called
  # "rancher-prime", so a search for the prime channel also returns their rows,
  # and an unscoped match resolves to a chart the prime repo does not carry.
  # Keep only this repository's "rancher" chart, which also drops the header.
  search="$(printf '%s\n' "$search" | grep "^${repo}/rancher[[:space:]]" || true)"

  if [ "$tag" = "head" ]; then
    printf '%s\n' "$search" \
      | awk '{print $2}' | sort -V | tail -1 | tr -d '[:space:]'
    return 0
  fi

  case "$repo" in
    rancher-alpha) filter="-alpha" ;;
    rancher-latest) filter="-rc" ;;
    *) filter="" ;;
  esac

  if [ -n "$filter" ]; then
    printf '%s\n' "$search" \
      | grep "$vs" | grep -- "$filter" \
      | awk '{print $2}' | sort -V | tail -1 | tr -d '[:space:]'
  else
    # No channel filter (prime / community stable / exact pin). A plain version
    # like 2.13.3 must outrank its own pre-release/hotfix siblings (2.13.3-hotfix
    # -751b.1), which a bare `sort -V` would rank higher. Prefix a stability key
    # (1 = GA, 0 = pre-release) so GA wins for the same base, then sort by it.
    printf '%s\n' "$search" | grep "$vs" \
      | awk '{ v=$2; stab=(v ~ /-/) ? "0" : "1"; print stab "|" v }' \
      | sort -V -t'|' -k1,1 -k2,2 | tail -1 | cut -d'|' -f2 | tr -d '[:space:]'
  fi
}

# image_tag_normalize <tag> - the tag as the registry actually publishes it.
# Rancher tags every version with a leading "v", so a caller who writes the
# version the way helm does ("2.15.0") would otherwise ask for a tag that has
# never existed. Anything not starting with a digit is a name rather than a
# version ("head") and is left alone.
image_tag_normalize() {
  case "${1:?tag required}" in
    [0-9]*) printf 'v%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# tag_is_bare_minor <tag> - true for a plain "X.Y" or "vX.Y" with no patch and
# no suffix, which is how a caller asks for "the newest of that line".
tag_is_bare_minor() {
  case "${1:?tag required}" in
    v[0-9]*.[0-9]* | [0-9]*.[0-9]*)
      case "${1#v}" in
        *.*.* | *-*) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

# resolve_image_tag <image> <chart_version> <tag> - the tag handed to helm.
#
# A channel that pins an image uses the chart version. A community channel
# normally passes the requested tag through, because there the tag is what
# selects the build. The exception is a bare minor: Docker Hub publishes
# vX.Y.Z and vX.Y-head but never a bare vX.Y, so passing "2.14" through asks for
# a tag that cannot exist. Resolve it to the chart version, which is the newest
# of that line and what the caller meant.
#
# Both paths are normalized, so "2.15.0" and "v2.15.0" resolve identically.
resolve_image_tag() {
  local image="$1" version="$2" tag="$3"
  if [ -n "$image" ]; then
    image_tag_normalize "$version"
  elif [ -n "$version" ] && tag_is_bare_minor "$tag"; then
    image_tag_normalize "$version"
  else
    image_tag_normalize "$tag"
  fi
}

# --- image preflight ---------------------------------------------------------
# A wrong image tag is otherwise invisible until the pod has been retrying for
# minutes and `kubectl rollout status` finally times out. The registry can
# answer "does this tag exist" in about a second, so ask before installing.
#
# The parsing helpers are pure; only image_exists talks to a registry.

# image_registry_host <image> - registry a reference resolves to. A first path
# segment counts as a registry only when it looks like a host, so
# "rancher/rancher" is Docker Hub while "stgregistry.suse.com/rancher/rancher"
# is not.
image_registry_host() {
  local image="${1:?image required}" first="${1%%/*}"
  case "$image" in
    */*) ;;
    *)
      printf 'docker.io'
      return 0
      ;;
  esac
  case "$first" in
    localhost | *.* | *:*) printf '%s' "$first" ;;
    *) printf 'docker.io' ;;
  esac
}

# image_repo_path <image> - repository path as the registry v2 API expects it.
# Docker Hub implies "library/" for single-segment names.
image_repo_path() {
  local image="${1:?image required}" host
  host="$(image_registry_host "$image")"
  local path="$image"
  case "$image" in
    "$host"/*) path="${image#"$host"/}" ;;
  esac
  if [ "$host" = docker.io ] && [ "${path%%/*}" = "$path" ]; then
    path="library/$path"
  fi
  printf '%s' "$path"
}

# image_tag_suggestions <image> <tag> - published tags containing the requested
# one, so a near miss like "v2.15" can point at the real "v2.15-head" and
# "v2.15.0". Architecture variants are dropped, and rolling head and GA tags are
# ranked above pre-releases: for a bare minor those two are what the caller
# almost always meant, and a plain version sort would bury them under every rc
# and alpha. Per-commit build tags are dropped as noise. Requires skopeo; prints
# nothing without it.
image_tag_suggestions() {
  local image="${1:?image required}" tag="${2:?tag required}"
  command -v skopeo >/dev/null 2>&1 || return 0
  skopeo list-tags "docker://${image}" 2>/dev/null \
    | sed -n 's/.*"\(.*\)".*/\1/p' \
    | grep -F "$tag" \
    | grep -vE -- '-(amd64|arm64|arm|s390x|ppc64le|windows.*)$' \
    | grep -vE -- '-[0-9a-f]{7,}(-|$)' \
    | grep -vx "$tag" \
    | awk '{ prio = ($0 ~ /-head$/ || $0 !~ /-/) ? 1 : 0; print prio "|" $0 }' \
    | sort -V -t'|' -k1,1 -k2,2 | tail -5 | cut -d'|' -f2 || true
}

# image_tag_is_valid <tag> - the OCI tag grammar: an alphanumeric or underscore
# first, then up to 127 more of alphanumeric, dot, dash or underscore.
#
# Worth checking separately because the common way to get this wrong is a
# Kubernetes version, where "+" carries the build metadata (v1.35.2+k3s1) and is
# legal there but not in a tag. The registry has no say in it.
image_tag_is_valid() {
  case "${1:?tag required}" in
    '' | [!A-Za-z0-9_]*) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 128 ]
}

# image_exists <image> <tag> - 0 the tag exists, 1 the registry says it does
# not, 2 no usable answer (gated registry, no credentials, network trouble).
# Only a definitive 1 is worth failing a run over.
image_exists() {
  local image="${1:?image required}" tag="${2:?tag required}" out rc
  # A tag no registry can hold is a definitive no, not an inconclusive one.
  # skopeo rejects it as "invalid reference format", which is neither a 404 nor
  # a transport problem, so without this it would downgrade to a warning and the
  # run would proceed to a pull that cannot succeed.
  image_tag_is_valid "$tag" || return 1
  if command -v skopeo >/dev/null 2>&1; then
    out="$(skopeo inspect --raw "docker://${image}:${tag}" 2>&1)" && return 0
    case "$out" in
      *"manifest unknown"* | *"was not found"* | *"not found"* | *"404"*) return 1 ;;
      *) return 2 ;;
    esac
  fi

  command -v curl >/dev/null 2>&1 || return 2
  local host repo url code token bundle curl_args=(-sS -o /dev/null -w '%{http_code}')
  host="$(image_registry_host "$image")"
  repo="$(image_repo_path "$image")"
  bundle="$(ca_bundle)"
  [ -n "$bundle" ] && curl_args+=(--cacert "$bundle")

  if [ "$host" = docker.io ]; then
    url="https://registry-1.docker.io/v2/${repo}/manifests/${tag}"
    token="$(curl -sS ${bundle:+--cacert "$bundle"} \
      "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" 2>/dev/null \
      | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
    [ -n "$token" ] || return 2
    curl_args+=(-H "Authorization: Bearer $token")
  else
    url="https://${host}/v2/${repo}/manifests/${tag}"
  fi

  rc=0
  code="$(curl "${curl_args[@]}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "$url" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || return 2
  case "$code" in
    2*) return 0 ;;
    404) return 1 ;;
    *) return 2 ;;
  esac
}

# image_prime_flavour <image> <tag> - "prime", "community", "missing" or
# "unknown".
#
# Rancher reports itself as Prime when RANCHER_VERSION_TYPE=prime is baked into
# the image (rancher/rancher pkg/version/version.go), and the dashboard reads
# that back to gate Prime-only UI extensions.
#
# This is a property of the individual image and cannot be inferred from the
# registry or the tag shape. Observed counter-examples to every tempting rule:
# registry.rancher.com serves prime for v2.14.4 but community for
# v2.14.2-hotfix-64aa.1; on stgregistry the -rc and -alpha builds are prime
# while -head and -rcs- are not. So read the image rather than guess.
#
# Requires skopeo to read the config blob. Without it, or when the read fails,
# the answer is unknown; a tag the registry does not have is reported as missing
# so a typo is not mistaken for an unreadable image.
image_prime_flavour() {
  local image="${1:?image required}" tag="${2:?tag required}" cfg
  local -a tls=()
  is_true "${MUSTER_REGISTRY_INSECURE:-}" && tls=(--tls-verify=false)
  if command -v skopeo >/dev/null 2>&1; then
    if cfg="$(skopeo inspect --config "${tls[@]}" "docker://${image}:${tag}" 2>/dev/null)"; then
      case "$cfg" in
        *'"RANCHER_VERSION_TYPE=prime"'*) printf 'prime' ;;
        *) printf 'community' ;;
      esac
      return 0
    fi
  fi
  local rc=0
  image_exists "$image" "$tag" || rc=$?
  [ "$rc" -eq 1 ] && {
    printf 'missing'
    return 0
  }
  printf 'unknown'
}

# image_newest_ga <image> [minor] - highest vX.Y.Z tag a registry publishes,
# optionally within one X.Y line. Pre-releases are ignored, so what comes back
# is that line's real GA ceiling.
image_newest_ga() {
  local image="${1:?image required}" minor="${2:-}"
  command -v skopeo >/dev/null 2>&1 || return 0
  skopeo list-tags "docker://${image}" 2>/dev/null \
    | sed -n 's/.*"\(.*\)".*/\1/p' \
    | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' \
    | sed 's/^v//' \
    | grep -E "^${minor:+${minor}\.}" \
    | sort -V | tail -1
}

# helm_missing_tag_hint <image> <tag> - an extra line of explanation when a tag
# is absent, or nothing when there is nothing useful to add.
#
# A release line is published to Docker Hub only up to some patch, after which
# further patches ship to the prime registries alone. Where that stops differs
# per line and moves over time, so compare what the registry actually serves
# rather than encoding a rule that will rot.
helm_missing_tag_hint() {
  local image="${1:?image required}" tag="${2:?tag required}" newest asked
  case "$image" in
    rancher/rancher | docker.io/*) ;;
    *) return 0 ;;
  esac
  asked="$(printf '%s' "$tag" | sed 's/^v//')"
  case "$asked" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) return 0 ;;
  esac
  # Compare within the line: the cut-off is per release line, so a 2.14 patch
  # must be measured against the newest 2.14 on Docker Hub, not against 2.15.
  local minor="${asked%.*}"
  newest="$(image_newest_ga "$image" "$minor")"
  [ -n "$newest" ] || return 0
  [ "$asked" = "$newest" ] && return 0
  [ "$(printf '%s\n%s\n' "$asked" "$newest" | sort -V | tail -1)" = "$asked" ] || return 0
  printf 'Docker Hub carries the %s line only up to %s; later patches go to the prime registries only. Try --repo rancher-prime-ga, or rancher-latest for a pre-release.' "$minor" "$newest"
}

# helm_verify_image - confirm the resolved image:tag is pullable before helm is
# asked to install it. Set MUSTER_SKIP_IMAGE_CHECK=1 to bypass.
helm_verify_image() {
  is_true "${MUSTER_SKIP_IMAGE_CHECK:-}" && return 0
  local image="${RANCHER_IMAGE:-rancher/rancher}"
  local tag="${RANCHER_IMAGE_TAG_RESOLVED:?RANCHER_IMAGE_TAG_RESOLVED is required}"

  # Assign through || so a non-zero return is a value, not a `set -e` abort.
  local rc=0
  image_exists "$image" "$tag" || rc=$?
  case "$rc" in
    0)
      log_ok "image ${image}:${tag} is pullable"
      return 0
      ;;
    2)
      log_warn "could not verify ${image}:${tag} (gated registry or network); continuing"
      return 0
      ;;
  esac

  local hint line why
  hint="$(image_tag_suggestions "$image" "$tag" || true)"
  if [ -n "$hint" ]; then
    log_err "closest published tags:"
    while IFS= read -r line; do
      printf '  %s\n' "$line" >&2
    done <<<"$hint"
  fi
  why="$(helm_missing_tag_hint "$image" "$tag" || true)"
  [ -n "$why" ] && log_err "$why"
  die "image ${image}:${tag} does not exist in the registry (repo=${RANCHER_REPO:-?}, requested version=${RANCHER_IMAGE_TAG:-?}).
  A channel without a pinned image passes --version through to the tag verbatim, so it must name a real tag.
  Set MUSTER_SKIP_IMAGE_CHECK=1 to install anyway."
}

# --- keep-fresh (freshness-aware promotion) ----------------------------------
# When PREFER_STAGING is on and the requested tag is a rolling community head
# tag (head or vX.Y-head), compare the community head image date against the
# newest SUSE staging build and, when staging is newer, rewrite the backend to
# that staging channel. A concrete version pin is an explicit override and is
# never touched. The image registries involved are anonymously pullable, so no
# credentials are required. Mirrors the date logic in list-rancher-versions.

# index_rancher_dates - read a chart index.yaml on stdin, emit one
# "stab|version|created" row per rancher chart entry (stab: 1 GA, 0 pre-release,
# so GA outranks same-base pre-releases under sort -V). Pure.
index_rancher_dates() {
  awk '
    /^  [a-zA-Z0-9_-]+:$/ { sub(/:$/, "", $1); chart=$1; next }
    /^  - apiVersion:/ {
      if (chart == "rancher" && ver != "") {
        stab = (ver ~ /-/) ? "0" : "1"; print stab "|" ver "|" created
      }
      ver=""; created=""; next
    }
    /^    version:/ { ver=$2;     gsub(/"/, "", ver) }
    /^    created:/ { created=$2; gsub(/"/, "", created) }
    END {
      if (chart == "rancher" && ver != "") {
        stab = (ver ~ /-/) ? "0" : "1"; print stab "|" ver "|" created
      }
    }
  '
}

# newest_dated <version_regex> <prerelease_filter> - read "stab|version|created"
# rows on stdin, keep those whose version matches <version_regex> (empty = any)
# and contains <prerelease_filter> (empty = any), and print "version|YYYY-MM-DD"
# of the newest (sort -V on stab then version). Pure.
newest_dated() {
  local vre="$1" filter="$2" rows
  rows="$(cat)"
  [ -n "$vre" ] && rows="$(printf '%s\n' "$rows" | grep -E "^[01][|]${vre}" || true)"
  [ -n "$filter" ] && rows="$(printf '%s\n' "$rows" | grep -- "$filter" || true)"
  [ -n "$rows" ] || return 0
  printf '%s\n' "$rows" | sort -V -t'|' -k1,1 -k2,2 | tail -1 \
    | awk -F'|' '{ d=$3; sub(/T.*/, "", d); print $2 "|" d }'
}

# parse_dockerhub_date <json_text> - extract the last_updated date (YYYY-MM-DD)
# from a Docker Hub tag API response. Pure.
parse_dockerhub_date() {
  printf '%s' "$1" | grep -oE '"last_updated":"[^"]+"' | head -1 \
    | sed -E 's/.*:"([^T]+)T.*/\1/'
}

# _freshness_curl <url> - GET a URL with the system CA bundle, quiet on failure.
_freshness_curl() {
  local url="$1" ca
  local -a args=(-fsSL)
  ca="$(ca_bundle)"
  [ -n "$ca" ] && args+=(--cacert "$ca")
  curl "${args[@]}" "$url" 2>/dev/null
}

# fetch_index_dates <channel> - download a channel index.yaml and parse it.
fetch_index_dates() {
  _freshness_curl "$(repo_url "$1")/index.yaml" | index_rancher_dates
}

# fetch_dockerhub_date <tag> - resolve a Docker Hub rancher/rancher tag date.
fetch_dockerhub_date() {
  parse_dockerhub_date \
    "$(_freshness_curl "https://hub.docker.com/v2/repositories/rancher/rancher/tags/$1")"
}

# freshness_maybe_promote - the gated promotion. No-op unless PREFER_STAGING is
# truthy and the tag is a rolling head tag. Rewrites RANCHER_REPO and
# RANCHER_IMAGE_TAG in place when the newest staging build outdates head.
freshness_maybe_promote() {
  is_true "${PREFER_STAGING:-}" || return 0
  case "$RANCHER_IMAGE_TAG" in
    head | *-head) ;;
    *) return 0 ;;
  esac

  local minor vre
  minor="$(version_string "$RANCHER_IMAGE_TAG")"
  if [ "$minor" = head ]; then
    vre=""
  else
    vre="$(printf '%s' "$minor" | sed 's/\./[.]/g')([.]|-)"
  fi

  local head_date
  head_date="$(fetch_dockerhub_date "$RANCHER_IMAGE_TAG")"
  if [ -z "$head_date" ]; then
    log_warn "keep-fresh: no Docker Hub date for '$RANCHER_IMAGE_TAG'; keeping community"
    return 0
  fi

  local best_ch="" best_ver="" best_date="" ch rows pick ver date filter
  for ch in rancher-latest rancher-alpha; do
    case "$ch" in
      rancher-latest) filter="-rc" ;;
      rancher-alpha) filter="-alpha" ;;
    esac
    rows="$(fetch_index_dates "$ch" || true)"
    [ -n "$rows" ] || continue
    pick="$(printf '%s\n' "$rows" | newest_dated "$vre" "$filter")"
    [ -n "$pick" ] || continue
    ver="${pick%%|*}"
    date="${pick#*|}"
    if [ -z "$best_date" ] || [ "$date" \> "$best_date" ]; then
      best_ch="$ch"
      best_ver="$ver"
      best_date="$date"
    fi
  done

  # head_date is a bare YYYY-MM-DD (Docker Hub last_updated, truncated at T);
  # the chart created field is a full ISO timestamp. Compare on the date part
  # only so a same-day staging build is a tie (kept community), not a win.
  local best_day="${best_date%%T*}"
  if [ -n "$best_date" ] && [ "$best_day" \> "$head_date" ]; then
    log_info "keep-fresh: PROMOTE community -> ${best_ch} (${best_ver}, ${best_date} newer than ${RANCHER_IMAGE_TAG} ${head_date})"
    RANCHER_REPO="$best_ch"
    RANCHER_IMAGE_TAG="v${best_ver}"
    export RANCHER_REPO RANCHER_IMAGE_TAG
  else
    log_info "keep-fresh: community ${RANCHER_IMAGE_TAG} (${head_date}) still newest (staging best ${best_date:-none}); no change"
  fi
}

# helm_resolve_version - orchestrate the impure resolution against a live helm.
# Validates RANCHER_REPO, adds/updates the repo, runs the search, and exports:
#   RANCHER_CHART_URL RANCHER_IMAGE RANCHER_CHART_VERSION RANCHER_IMAGE_TAG_RESOLVED
helm_resolve_version() {
  freshness_maybe_promote
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
  search="$(helm search repo "${repo}/rancher" --devel --versions 2>/dev/null || true)"
  RANCHER_CHART_VERSION="$(resolve_chart_version "$repo" "$tag" "$search" || true)"
  if [ -z "$RANCHER_CHART_VERSION" ]; then
    local available why
    available="$(printf '%s\n' "$search" | sed -n '1!p' | awk '{print $2}' | sort -V | tail -5 | tr '\n' ' ')"
    why="$(helm_missing_tag_hint "${RANCHER_IMAGE:-rancher/rancher}" "$tag" || true)"
    [ -n "$available" ] && log_err "newest in ${repo}: ${available}"
    [ -n "$why" ] && log_err "$why"
    die "no chart version in ${repo} matches '${tag}'"
  fi

  RANCHER_IMAGE_TAG_RESOLVED="$(resolve_image_tag "$RANCHER_IMAGE" "$RANCHER_CHART_VERSION" "$tag")"
  # A branch head ships no chart of its own, so testing one means running it
  # against the newest chart of the line it came from. That pairing cannot be
  # derived, since the two do not share a version, so it is stated instead.
  #
  # A full reference also moves the registry, because the build wanted is not
  # always in the channel's own registry: Prime publishes no master head, so
  # pairing a Prime chart with one means crossing to Docker Hub.
  if [ -n "${RANCHER_IMAGE_TAG_OVERRIDE:-}" ]; then
    local ovr="$RANCHER_IMAGE_TAG_OVERRIDE"
    case "$ovr" in
      */*)
        RANCHER_IMAGE="${ovr%:*}"
        RANCHER_IMAGE_TAG_RESOLVED="${ovr##*:}"
        ;;
      *) RANCHER_IMAGE_TAG_RESOLVED="$ovr" ;;
    esac
    log_info "image overridden: ${RANCHER_IMAGE:-rancher/rancher}:${RANCHER_IMAGE_TAG_RESOLVED} (chart stays $RANCHER_CHART_VERSION)"
  fi
  export RANCHER_CHART_URL RANCHER_IMAGE RANCHER_CHART_VERSION RANCHER_IMAGE_TAG_RESOLVED
  log_info "resolved: repo=$repo chart=$RANCHER_CHART_VERSION image=${RANCHER_IMAGE:-rancher/rancher} tag=$RANCHER_IMAGE_TAG_RESOLVED"
  helm_verify_image
}

# helm_cert_manager_oci_ref - the OCI reference for the cert-manager chart in the
# mirror, or nothing when the install is not airgapped. helm on this host reaches
# the mirror at its published address (MIRROR_REGISTRY, e.g. localhost:5000), not
# by the in-cluster name the nodes use. The repository path mirrors the source
# (quay.io/jetstack/charts/cert-manager) with its registry stripped, which is
# what lib/mirror.sh copies it to.
helm_cert_manager_oci_ref() {
  is_true "${AIRGAP:-}" || return 0
  [ -n "${MIRROR_REGISTRY:-}" ] || return 0
  printf 'oci://%s/jetstack/charts/cert-manager' "$MIRROR_REGISTRY"
}

# helm_cert_manager_oci_available <oci_ref> <bare_version> - true when the chart
# is actually in the mirror, so the caller can fall back rather than fail if the
# mirror was filled without it.
helm_cert_manager_oci_available() {
  local ref="${1:?oci ref required}" ver="${2:?version required}"
  command -v skopeo >/dev/null 2>&1 || return 1
  local -a tls=()
  is_true "${MIRROR_INSECURE:-}" && tls=(--tls-verify=false)
  skopeo inspect --raw "${tls[@]}" "docker://${ref#oci://}:${ver}" >/dev/null 2>&1
}

# helm_install_cert_manager_upstream <kubeconfig> <cmver> - the non-airgap path:
# fetch and SHA256-verify the CRD manifest from the GitHub release, apply it, then
# install the chart from the jetstack repo. The checksum comes from the release
# asset digest unless CERT_MANAGER_CRDS_SHA256 (or the source pin map) pins it.
helm_install_cert_manager_upstream() {
  local kc="${1:?kubeconfig path required}" cmver="${2:?cert-manager version required}"
  local pin="${CERT_MANAGER_CRDS_SHA256:-${MUSTER_CERT_MANAGER_CRDS_SHA256[$cmver]:-}}"
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
}

# helm_install_cert_manager <kubeconfig> - install cert-manager with its CRDs.
#
# Airgapped, the chart and its CRDs come from the mirror as an OCI artifact, so
# nothing is fetched from charts.jetstack.io or a GitHub release. The chart's own
# crds.enabled=true installs the CRDs, which removes the one external host fetch
# an airgapped install otherwise still made. Otherwise, and as a fallback when the
# mirror was filled without the chart, the upstream (verified GitHub CRDs +
# jetstack repo) path is used.
helm_install_cert_manager() {
  local kc="${1:?kubeconfig path required}"
  local cmver="${CERT_MANAGER_VERSION:-$CERT_MANAGER_VERSION_DEFAULT}"
  require_cmd kubectl
  require_cmd helm

  local oci
  oci="$(helm_cert_manager_oci_ref)"
  if [ -n "$oci" ] && helm_cert_manager_oci_available "$oci" "${cmver#v}"; then
    local -a args=(
      --kubeconfig "$kc" upgrade --install cert-manager "$oci"
      --version "${cmver#v}"
      --namespace cert-manager --create-namespace
      --set crds.enabled=true --wait --timeout 5m
    )
    is_true "${MIRROR_INSECURE:-}" && args+=(--plain-http)
    log_info "cert-manager $cmver (mirror OCI chart, CRDs bundled)"
    helm "${args[@]}"
  else
    [ -n "$oci" ] && log_warn "cert-manager OCI chart not in mirror; using jetstack repo + GitHub CRDs"
    helm_install_cert_manager_upstream "$kc" "$cmver"
  fi
  kubectl --kubeconfig "$kc" -n cert-manager rollout status \
    deploy/cert-manager-webhook --timeout=180s
}

# helm_install_rancher <kubeconfig> <hostname> - install cert-manager and
# Rancher. Assumes helm_resolve_version has run (RANCHER_* exported and the
# Rancher chart repo added).
helm_install_rancher() {
  local kc="${1:?kubeconfig path required}" host="${2:?hostname required}"
  require_cmd kubectl
  require_cmd helm

  helm_install_cert_manager "$kc"

  local image="${RANCHER_IMAGE:-rancher/rancher}"
  local agent_image="${image%/*}/rancher-agent"
  local tag="$RANCHER_IMAGE_TAG_RESOLVED"
  # Airgap hands the agent its repository path alone, because Rancher prefixes
  # systemDefaultRegistry onto CATTLE_AGENT_IMAGE. A fully qualified value would
  # resolve to <mirror>/<upstream-host>/rancher/rancher-agent, which the mirror
  # does not hold; the bare path resolves to <mirror>/rancher/rancher-agent,
  # which it does.
  if is_true "${AIRGAP:-}"; then
    agent_image="$(airgap_repo_path "$agent_image")"
  fi
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
  # External mode publishes Rancher behind a tunnel whose certificate Rancher
  # did not issue, so agents must validate against the system trust store. The
  # chart value is set here rather than patched afterwards: patching leaves a
  # window where Rancher is already serving in strict mode, and anything that
  # registers in that window is set up against the wrong expectation.
  if is_true "${EXTERNAL:-}"; then
    args+=(--set "agentTLSMode=system-store")
  fi
  # Airgap: Rancher rewrites its system images to the private registry, and
  # publishes that choice as the system-default-registry setting. Components
  # that build an image reference themselves read that setting, so it has to be
  # set for them to have anything to prefix with.
  if is_true "${AIRGAP:-}"; then
    local node_registry
    node_registry="$(airgap_registry_host "$MIRROR_REGISTRY")"
    args+=(--set "systemDefaultRegistry=${node_registry}")
    # Rancher otherwise clones its three chart repositories from git.rancher.io
    # on startup, which an airgapped install cannot reach. The same charts are
    # already baked into the image, so use those instead.
    args+=(--set "useBundledSystemChart=true")
    log_info "airgap: systemDefaultRegistry=${node_registry}, bundled system charts"
  fi
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
