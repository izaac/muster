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

# The channels a `prime` row searches, in release-ladder order. The GA channel is
# first and not optional: charts.optimus stopped receiving final Prime releases at
# 2.14.3, so every newer GA lands only on charts.rancher.com. Pre-release channels
# alone would resolve "newest release" to an rc of a version that has shipped.
MUSTER_PRIME_CHANNELS=(rancher-prime-ga rancher-latest rancher-alpha)

# A GA row reads one edition's release channel, and the kind names the edition
# because the same version number is a different build on each side.
declare -gA MUSTER_GA_CHANNEL=(
  ["prime-ga"]="rancher-prime-ga"
  ["community-ga"]="rancher-com-rc"
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

# --- the release ladder ------------------------------------------------------
# Ordering a chart version is not string ordering: 2.13.10 is newer than 2.13.9,
# rc10 is newer than rc2, and a final release outranks its own release candidate.
# One awk program states the ladder, so every caller orders versions the same way.
#
# Rank 3 is a final release, 2 an rc, 1 an alpha and 0 anything else at all: a
# hotfix build, a commit-named head, an unrecognised suffix. A hotfix is a build
# off to one side rather than a step towards the release, so it never outranks an
# rc. The key is "maj.min.patch|rank|stage" so `sort -V` on its three fields gets
# the true order (base version, then rung, then the stage number).
_MUSTER_VERSION_AWK='
function ladder(v,   m, base, pre, a, n, num) {
  m = v
  sub(/^v/, "", m)
  base = m
  pre = ""
  if (index(m, "-") > 0) {
    pre = substr(m, index(m, "-"))
    base = substr(m, 1, index(m, "-") - 1)
  }
  if (base !~ /^[0-9]+[.][0-9]+([.][0-9]+)?$/) return "0.0.0|0|0"
  n = split(base, a, ".")
  base = a[1] "." a[2] "." (n >= 3 ? a[3] : "0")
  if (pre == "") return base "|3|0"
  num = pre
  gsub(/[^0-9]/, "", num)
  if (num == "") num = "0"
  if (pre ~ /^-rc[.]?[0-9]+$/) return base "|2|" num
  if (pre ~ /^-alpha[.]?[0-9]+$/) return base "|1|" num
  return base "|0|0"
}
function rank_of(v,   parts) {
  split(ladder(v), parts, "|")
  return parts[2]
}
function on_line(v, line,   rest) {
  sub(/^v/, "", v)
  if (substr(v, 1, length(line)) != line) return 0
  rest = substr(v, length(line) + 1)
  return rest == "" || substr(rest, 1, 1) == "." || substr(rest, 1, 1) == "-"
}
'

# version_line_re <line> - an ERE that matches a version only at a line boundary,
# so 2.1 never swallows 2.15 and 2.12.5 never swallows 2.12.50. Pure.
version_line_re() {
  local line="${1:?line required}"
  printf '^v?%s([.-]|$)' "$(printf '%s' "$line" | sed 's/[.]/\\./g')"
}

# highest_version - the ladder-highest version read on stdin, one version per
# line. Pure; prints nothing for empty input.
highest_version() {
  awk "$_MUSTER_VERSION_AWK"' { print ladder($0) "|" $0 }' \
    | sort -V -t'|' -k1,1 -k2,2 -k3,3 -k4,4 | tail -1 | cut -d'|' -f4- | tr -d '[:space:]'
}

# versions_on_line <line> - the versions read on stdin that belong to <line>,
# anchored at a separator. Pure.
versions_on_line() {
  local line="${1:?line required}"
  grep -E -- "$(version_line_re "$line")" || true
}

# chart_created_stamp <created> - an index timestamp trimmed for a report. Head
# charts publish several times a day, so a date alone does not identify which
# build ran; the index carries nanoseconds, which is more precision than a report
# needs. Pure.
chart_created_stamp() {
  local text="${1:-}"
  text="${text/T/ }"
  case "$text" in
    *' '*) printf '%s' "${text:0:16}" ;;
    *) printf '%s' "${text:0:10}" ;;
  esac
}

# chart_released_date <created> - the publication date alone, for the variable a
# job reads to decide whether a line is still publishing. Pure.
chart_released_date() {
  local text="${1:-}"
  printf '%s' "${text%%[T ]*}"
}

# resolve_chart_version <repo> <tag> <search_text> - pick the chart version from
# the lines of `helm search repo <repo> --devel --versions`. Pure; prints the
# version (empty if nothing matched). Based on the ansible shell, but every
# ordering goes through the release ladder above: helm sorts pre-release
# identifiers lexically, so 2.x-alpha9 outranks 2.x-alpha14 ('9' > '1') and a
# plain `head -1` would pick a stale alpha.
#
# Line matching is anchored at a separator, so a 2.1 request never answers with
# 2.15 and a 2.12.5 request never answers with 2.12.50.
resolve_chart_version() {
  local repo="$1" tag="$2" search="$3" dates="${4:-}" vs filter pick line versions
  vs="$(version_string "$tag")"

  # `helm search repo <name>` is a keyword search over every configured
  # repository, not a listing of one. Both staging repos publish a chart called
  # "rancher-prime", so a search for the prime channel also returns their rows,
  # and an unscoped match resolves to a chart the prime repo does not carry.
  # Keep only this repository's "rancher" chart, which also drops the header.
  search="$(printf '%s\n' "$search" | grep "^${repo}/rancher[[:space:]]" || true)"

  if [ "$tag" = "head" ]; then
    # "The newest thing this channel builds": the newest line first, then that
    # line's newest head build, falling back to the line's newest release for a
    # channel that publishes no head chart at all.
    versions="$(printf '%s\n' "$search" | awk '$2 ~ /^[0-9]/ { print $2 }')"
    line="$(chart_release_line "$(printf '%s\n' "$versions" | highest_version)")"
    [ -n "$line" ] || return 0
    pick="$(newest_head_on_line "$line" "$dates" || true)"
    if [ -z "$pick" ]; then
      pick="$(printf '%s\n' "$versions" \
        | versions_on_line "$line" | grep -- '-head$' | highest_version || true)"
    fi
    if [ -z "$pick" ]; then
      pick="$(printf '%s\n' "$versions" \
        | versions_on_line "$line" | grep -v -- '-head$' | highest_version || true)"
    fi
    printf '%s' "$pick"
    return 0
  fi

  # A tag carrying a pre-release suffix may name one published chart outright, so
  # take that chart when it exists. Without this the channel filter below still
  # applies, and a pin like 2.15.1-<sha>-head on rancher-latest resolves to
  # nothing because it is not an -rc, even though it is sitting in the listing.
  #
  # Only ever an addition: when the tag matches no chart exactly, resolution
  # falls through to the filter, so every tag that resolved before still resolves
  # to the same chart.
  case "$tag" in
    *-*)
      local exact
      exact="$(printf '%s\n' "$search" | awk -v want="${tag#v}" '$2 == want { print $2; exit }')"
      if [ -n "$exact" ]; then
        printf '%s' "$exact"
        return 0
      fi
      ;;
  esac

  case "$repo" in
    rancher-alpha) filter="-alpha" ;;
    # The Prime pre-release channels are being consolidated: the release team is
    # moving the alphas into this one, and eventually the head charts too. An
    # alpha here today would be invisible to an -rc filter, and the line would
    # read as absent rather than pre-rc. Accept both shapes now: the channel
    # carries no alpha yet, so this changes nothing until it does, and on a line
    # holding both the ladder still prefers the rc.
    rancher-latest) filter="-rc|-alpha" ;;
    *) filter="" ;;
  esac

  # Anchor on the separator: vs is the line or the patch the tag names, never a
  # prefix of a longer number. A line request deliberately excludes commit-named
  # head charts: such a chart is a new identity on every commit, so a fixed input
  # resolving to one would deploy a different build on every run. Pin one in full
  # to run it on purpose, which the exact match above allows.
  pick="$(printf '%s\n' "$search" | awk '$2 ~ /^[0-9]/ { print $2 }' \
    | versions_on_line "$vs" | grep -v -- '-head$' || true)"
  if [ -n "$filter" ]; then
    pick="$(printf '%s\n' "$pick" | grep -E -- "$filter" || true)"
  fi
  printf '%s' "$(printf '%s\n' "$pick" | highest_version)"
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

# --- chart / server line skew ------------------------------------------------
# A chart and a server image are versioned separately and can be paired freely,
# which is useful on purpose and damaging by accident. Neither version string
# states the pairing, because a head chart and a head image name their line
# differently, so read the line the server actually carries and compare.

# chart_release_line <chart_version> - the X.Y line a chart belongs to, on
# stdout, or nothing for a version that names no line. Pure. Covers both head
# chart shapes: 2.16.0-<sha>-head, the release team's scheme with the patch, and
# 2.15-<sha>-head, the per-branch one.
chart_release_line() {
  local v="${1:-}"
  v="${v%%-*}"
  v="${v#v}"
  case "$v" in
    [0-9]*.[0-9]*) printf '%s' "$v" | cut -d. -f1,2 ;;
  esac
}

# version_line_of <tag> - the X.Y line a tag names, or nothing for a name such
# as "head". The same question chart_release_line answers, named for the callers
# that ask it about an image tag rather than a chart version. Pure.
version_line_of() { chart_release_line "${1:-}"; }

# image_chart_line <image> <tag> - the X.Y line of the chart catalog a server
# runs, read from CATTLE_CHART_DEFAULT_BRANCH in its config, on stdout.
#
# A server does not take its system charts from the chart that deployed it. It
# clones rancher/charts at this branch, or from 2.16 reads them out of the
# rancher-assets image. Either way this value is the line the server behaves as,
# and the only place that line is stated.
image_chart_line() {
  local b
  command -v image_env >/dev/null 2>&1 || return 0
  b="$(image_env "${1:?image required}" "${2:?tag required}" CATTLE_CHART_DEFAULT_BRANCH)"
  case "$b" in
    dev-v[0-9]*.[0-9]* | release-v[0-9]*.[0-9]*) printf '%s' "${b#*-v}" ;;
  esac
}

# helm_line_skew_hint <chart_version> <chart_line> <image_line> - what a chart
# and server from different lines costs, on stdout, or nothing when they agree or
# either line is unknown. Pure.
#
# Worth saying because the pairing comes up and works. The components the chart
# pins are one line's and the system charts are the other's, and from 2.16 the
# difference decides whether the system charts arrive at all: that chart copies
# them out of rancher-assets with an initContainer, which an older chart does not
# have. Online the server falls back to cloning rancher/charts and the skew is
# invisible; airgapped there is nothing to clone.
helm_line_skew_hint() {
  local chart="${1:-}" cline="${2:-}" iline="${3:-}"
  [ -n "$cline" ] && [ -n "$iline" ] || return 0
  [ "$cline" = "$iline" ] && return 0
  printf 'chart %s is on the %s line but the server carries the %s chart catalog\n' \
    "$chart" "$cline" "$iline"
  printf 'components follow the chart and system charts follow the server; use the %s chart unless the skew is the point\n' \
    "$iline"
}

# helm_check_chart_line - warn when the resolved chart and image are from
# different release lines. Never fails a run: an unreadable image, a missing
# skopeo or an unrecognised branch value all simply say nothing.
helm_check_chart_line() {
  is_true "${MUSTER_SKIP_IMAGE_CHECK:-}" && return 0
  local image="${RANCHER_IMAGE:-rancher/rancher}"
  local tag="${RANCHER_IMAGE_TAG_RESOLVED:-}"
  [ -n "$tag" ] || return 0
  local cline iline line
  cline="$(chart_release_line "${RANCHER_CHART_VERSION:-}")"
  iline="$(image_chart_line "$image" "$tag")"
  while IFS= read -r line; do
    [ -n "$line" ] && log_warn "$line"
  done < <(helm_line_skew_hint "${RANCHER_CHART_VERSION:-}" "$cline" "$iline")
}

# --- keep-fresh (freshness-aware promotion) ----------------------------------
# When PREFER_STAGING is on and the requested tag is a rolling community head
# tag (head or vX.Y-head), compare the community head image date against the
# newest SUSE staging build and, when staging is newer, rewrite the backend to
# that staging channel. A concrete version pin is an explicit override and is
# never touched. The image registries involved are anonymously pullable, so no
# credentials are required. Mirrors the date logic in list-rancher-versions.

# index_rancher_entries - read a chart index.yaml on stdin, emit one
# "rank|version|created|appVersion" row per rancher chart entry (rank from the
# release ladder: 3 GA, 2 rc, 1 alpha, 0 anything else). Pure.
#
# appVersion is kept because a shipped chart states the image tag it was built
# with, and a GA row trusts the chart rather than its own version number.
index_rancher_entries() {
  awk "$_MUSTER_VERSION_AWK"'
    function emit() {
      if (chart != "rancher" || ver == "") return
      printf "%s|%s|%s|%s\n", rank_of(ver), ver, created, app
    }
    /^  [a-zA-Z0-9_-]+:$/ { sub(/:$/, "", $1); chart = $1; next }
    /^  - apiVersion:/ { emit(); ver = ""; created = ""; app = ""; next }
    /^    version:/ { ver = $2; gsub(/"/, "", ver) }
    /^    created:/ { created = $2; gsub(/"/, "", created) }
    /^    appVersion:/ { app = $2; gsub(/"/, "", app) }
    END { emit() }
  '
}

# index_rancher_dates - the three-column form of the above, for the callers that
# only need the date and the order. Pure.
index_rancher_dates() { index_rancher_entries | cut -d'|' -f1-3; }

# index_chart_released <version> - the index timestamp for one chart version,
# read as index rows on stdin. Pure.
index_chart_released() {
  local want="${1:?version required}"
  awk -F'|' -v want="$want" '$2 == want { print $3; exit }'
}

# index_line_max_final_patch <line> - the highest final-release patch a line has
# in one channel index, read as index rows on stdin, or -1 when it has none.
# Pure.
#
# Pre-releases and head builds do not count: the question is what shipped, so a
# candidate for a version that has not been released yet says nothing about
# whether the line is still publishing Community releases.
index_line_max_final_patch() {
  awk -F'|' -v line="${1:?line required}" '
    BEGIN { best = -1 }
    $2 ~ /^[0-9]+[.][0-9]+[.][0-9]+$/ {
      split($2, a, ".")
      if (a[1] "." a[2] != line) next
      if (a[3] + 0 > best) best = a[3] + 0
    }
    END { print best }
  '
}

# newest_release_version <version_regex> - read ladder rows on stdin and print
# "version|YYYY-MM-DD" of the highest RELEASE version matching the regex,
# excluding -head dev charts (a -head chart is the branch head, not a release).
# "Highest" is the release ladder: a final release outranks its own candidates,
# an rc outranks an alpha, and both outrank a hotfix of the same base. Pure.
newest_release_version() {
  local vre="$1" rows
  rows="$(grep -E "^[0-3][|]${vre}" | grep -v -- '-head' || true)"
  [ -n "$rows" ] || return 0
  printf '%s\n' "$rows" \
    | awk -F'|' "$_MUSTER_VERSION_AWK"' { print ladder($2) "|" $2 "|" $3 }' \
    | sort -V -t'|' -k1,1 -k2,2 -k3,3 -k4,4 | tail -1 \
    | awk -F'|' '{ d = $5; sub(/T.*/, "", d); print $4 "|" d }'
}

# newest_head_versions <version_regex> <n> - the newest <n> head charts matching
# the regex, read as ladder rows on stdin, newest first. Pure.
#
# The counterpart to newest_release_version: those are what a Prime row resolves
# to, these are what it deliberately will not, and naming them is what turns "no
# release" from a dead end into a choice. Ordered by publication date, because a
# commit-named chart carries no ordering of its own.
newest_head_versions() {
  local vre="$1" n="${2:-3}" rows
  rows="$(grep -E "^[0-3][|]${vre}" | grep -- '-head' || true)"
  [ -n "$rows" ] || return 0
  printf '%s\n' "$rows" \
    | awk -F'|' '{ print $3 "\t" $2 }' \
    | sort -r | head -"$n" | awk -F'\t' '{ print $2 }'
}

# version_ahead <a> <b> - true when version a is strictly newer than b, on the
# release ladder. An empty b counts as older than anything. Pure.
version_ahead() {
  local a="${1:-}" b="${2:-}" ka kb newest
  [ "$a" = "$b" ] && return 1
  [ -n "$a" ] || return 1
  [ -n "$b" ] || return 0
  ka="$(printf '%s\n' "$a" | awk "$_MUSTER_VERSION_AWK"' { print ladder($0) }')"
  kb="$(printf '%s\n' "$b" | awk "$_MUSTER_VERSION_AWK"' { print ladder($0) }')"
  [ "$ka" != "$kb" ] || return 1
  newest="$(printf '%s\n%s\n' "$ka" "$kb" | sort -V -t'|' -k1,1 -k2,2 -k3,3 | tail -1)"
  [ "$newest" = "$ka" ]
}

# _date_epoch <YYYY-MM-DD> - seconds since epoch, GNU date first then BSD.
_date_epoch() {
  date -d "$1" +%s 2>/dev/null || date -j -f '%Y-%m-%d' "$1" +%s 2>/dev/null
}

# date_age_days <yyyy-mm-dd> [now_yyyy-mm-dd] - whole days elapsed since <date>,
# or -1 when <date> is empty or cannot be parsed. A future date yields a negative
# number rather than -1, so a caller can tell "unparsable" from "not yet".
# Deterministic given its arguments. Pure.
date_age_days() {
  local d="${1:-}" now="${2:-$(today)}" de te
  [ -n "$d" ] || {
    printf '%s' -1
    return 0
  }
  de="$(_date_epoch "$d")" || de=""
  te="$(_date_epoch "$now")" || te=""
  if [ -z "$de" ] || [ -z "$te" ]; then
    printf '%s' -1
    return 0
  fi
  printf '%s' "$(((te - de) / 86400))"
}

# date_within_days <date> <today> <max_days> - true when <date> is no more than
# <max_days> before <today>; a future date is always within. Deterministic given
# its arguments.
date_within_days() {
  local d="$1" today="$2" max="$3" de te
  de="$(_date_epoch "$d")" || return 1
  te="$(_date_epoch "$today")" || return 1
  [ -n "$de" ] && [ -n "$te" ] || return 1
  [ "$(((te - de) / 86400))" -le "$max" ]
}

# freshness_prefer_prime <prime_ver> <community_ver> <prime_date> <today> <max>
# - the G4 cutoff, pure. Prefer the prime line unless the community line is
# strictly ahead of it (community has GA'd past staging), and only when the prime
# release is recent enough that the prime line is itself still alive. A tie
# prefers prime, because the same version built on the prime registry is a
# superset of the community one: it loads the Prime-only extensions the community
# build cannot. A community that never published the line counts as behind.
freshness_prefer_prime() {
  local prime_ver="$1" com_ver="$2" prime_date="$3" today="$4" max="$5"
  [ -n "$prime_ver" ] || return 1
  version_ahead "$com_ver" "$prime_ver" && return 1
  date_within_days "$prime_date" "$today" "$max"
}

# today - current date (YYYY-MM-DD), overridable in tests with MUSTER_TODAY.
today() { printf '%s' "${MUSTER_TODAY:-$(date +%F)}"; }

# _freshness_curl <url> - GET a URL with the system CA bundle, quiet on failure.
_freshness_curl() {
  local url="$1" ca
  local -a args=(-fsSL)
  ca="$(ca_bundle)"
  [ -n "$ca" ] && args+=(--cacert "$ca")
  curl "${args[@]}" "$url" 2>/dev/null
}

# fetch_index_url <chart_repo_url> - the raw index.yaml a chart channel serves.
#
# A 200 returns the body. A 404 returns nothing and success: a retired or
# never-published channel is a normal state for the Prime pre-release repos
# during their consolidation, and a row that names a minor rather than a channel
# should not care. Anything else fails, because a channel that is merely
# unreachable might hold the newest chart, and resolving from the rest would
# quietly deploy an older build.
fetch_index_url() {
  local base="${1:?url required}" out code body ca rc=0
  local -a args=(-sSL --max-time 20 -w '\n%{http_code}')
  ca="$(ca_bundle)"
  [ -n "$ca" ] && args+=(--cacert "$ca")
  out="$(curl "${args[@]}" "${base%/}/index.yaml" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || return 1
  code="${out##*$'\n'}"
  body="${out%$'\n'*}"
  case "$code" in
    200) printf '%s' "$body" ;;
    404) : ;;
    *) return 1 ;;
  esac
}

# fetch_index_entries_url <chart_repo_url> - download an index.yaml and parse
# every rancher entry into a ladder row. Returns the fetch status, so a caller
# that must distinguish "channel gone" from "channel unreachable" can.
#
# The status is checked before anything is piped: relying on the caller's
# pipefail would make a plain `x="$(fetch_index_entries_url ...)"` treat a failed
# fetch as success whenever this file is sourced by something without `set -o
# pipefail`, unit tests included.
fetch_index_entries_url() {
  local raw
  raw="$(fetch_index_url "${1:?url required}")" || return 1
  [ -n "$raw" ] || return 0
  printf '%s\n' "$raw" | index_rancher_entries
}

# fetch_index_entries <channel> - the same, for a known channel key.
fetch_index_entries() { fetch_index_entries_url "$(repo_url "$1")"; }

# fetch_index_dates_url <chart_repo_url> - the three-column form, which is all
# the freshness probe and the date ordering need. Checks the fetch status
# explicitly for the same reason as fetch_index_entries_url.
fetch_index_dates_url() {
  local raw
  raw="$(fetch_index_entries_url "${1:?url required}")" || return 1
  [ -n "$raw" ] || return 0
  printf '%s\n' "$raw" | cut -d'|' -f1-3
}

# fetch_index_dates <channel> - the same, for a known channel key.
fetch_index_dates() { fetch_index_dates_url "$(repo_url "$1")"; }

# freshness_newest_release <version_regex> <channel...> - the newest RELEASE
# chart for a line across the given channels (an rc, alpha or GA, but never a
# -head dev chart, which is the branch head and not a release), as
# "version|YYYY-MM-DD|channel" on stdout. Impure: reads each channel index.
freshness_newest_release() {
  local vre="$1"
  shift
  local ch pick best_ver="" best="" ver date
  for ch in "$@"; do
    pick="$(fetch_index_dates "$ch" 2>/dev/null | newest_release_version "$vre" || true)"
    [ -n "$pick" ] || continue
    ver="${pick%%|*}"
    date="${pick#*|}"
    if [ -z "$best_ver" ] || version_ahead "$ver" "$best_ver"; then
      best_ver="$ver"
      best="${ver}|${date}|${ch}"
    fi
  done
  printf '%s' "$best"
}

# freshness_maybe_promote - the gated promotion (--prefer-staging). No-op unless
# PREFER_STAGING is truthy and the tag is a rolling head tag. Rewrites
# RANCHER_REPO and RANCHER_IMAGE_TAG in place when the prime line has overtaken
# the community one.
#
# The signal is the G4 cutoff, not the head image's build date. A -head image
# keeps rebuilding on both registries long after a line's community release
# channel has stopped, so its date proves nothing (2.14's Docker Hub head was
# built this week while its community releases stopped at 2.14.3). Compare the
# newest community release chart for the line against the newest prime one
# instead: unless the community line is strictly ahead (it GA'd past staging),
# prefer the prime release when it is recent. A tie prefers prime, since the same
# version on the prime registry additionally loads the Prime-only extensions.
MUSTER_PRIME_MAX_AGE_DAYS="${MUSTER_PRIME_MAX_AGE_DAYS:-60}"
freshness_maybe_promote() {
  is_true "${PREFER_STAGING:-}" || return 0
  case "$RANCHER_IMAGE_TAG" in
    head | *-head) ;;
    *) return 0 ;;
  esac

  local minor vre
  minor="$(version_string "$RANCHER_IMAGE_TAG")"
  if [ "$minor" = head ]; then
    log_info "keep-fresh: master head has no release line to weigh; keeping community"
    return 0
  fi
  vre="$(printf '%s' "$minor" | sed 's/\./[.]/g')([.]|-)"

  local com prime com_ver prime_ver prime_date prime_ch rest
  com="$(freshness_newest_release "$vre" rancher-com-rc rancher-com-alpha)"
  prime="$(freshness_newest_release "$vre" rancher-latest rancher-alpha)"
  com_ver="${com%%|*}"
  prime_ver="${prime%%|*}"
  rest="${prime#*|}"
  prime_date="${rest%%|*}"
  prime_ch="${rest##*|}"

  if [ -z "$prime_ver" ]; then
    log_info "keep-fresh: no prime release for ${minor}; keeping community ${RANCHER_IMAGE_TAG}"
    return 0
  fi

  if freshness_prefer_prime "$prime_ver" "$com_ver" "$prime_date" "$(today)" "$MUSTER_PRIME_MAX_AGE_DAYS"; then
    log_info "keep-fresh: PROMOTE community -> ${prime_ch} (${prime_ver}; prime at or ahead of community ${com_ver:-none}, built ${prime_date})"
    RANCHER_REPO="$prime_ch"
    RANCHER_IMAGE_TAG="v${prime_ver}"
    export RANCHER_REPO RANCHER_IMAGE_TAG
  else
    log_info "keep-fresh: community ${minor} is ahead of prime (community ${com_ver:-none} vs prime ${prime_ver} ${prime_date}); no change"
  fi
}

# newest_head_on_line <line> <dates> - the most recently published head chart on
# one release line, from "stab|version|created" rows. Pure; empty when the rows
# carry no head chart for that line.
newest_head_on_line() {
  local line="${1:?line required}" dates="${2:-}" vre
  [ -n "$dates" ] || return 0
  vre="$(printf '%s' "$line" | sed 's/\./[.]/g')[.-]"
  printf '%s\n' "$dates" | newest_head_versions "$vre" 1
}

# resolve_head_pick <version_sort_winner> <dates> - refine "the newest chart in
# this channel" when that chart is commit-named. Pure.
#
# Version sort orders the release lines correctly, because a line is a real
# version, but inside a line a head chart is X.Y.Z-<sha>-head and the sha carries
# no order: sorting it picks whichever commit has the highest hex rather than the
# newest build. On the consolidated Prime channel that is not a near miss.
# Today rancher-latest resolves `head` to a 2.16 chart published on 14 August
# while the newest 2.16 chart was published today, because ffbd1cc9 outranks
# b29c3a6 as a string.
#
# The release team's own guidance is to order these by the index's creation date,
# so take the line from the version sort and the build from the date.
#
# Falls back to the version-sort answer whenever the winner is not a head chart
# or the line has no dated rows, so a channel of releases, or one whose index
# could not be read, resolves exactly as it did before.
resolve_head_pick() {
  local top="${1:-}" dates="${2:-}" line pick
  case "$top" in
    *-head) ;;
    *)
      printf '%s' "$top"
      return 0
      ;;
  esac
  line="$(chart_release_line "$top")"
  if [ -z "$line" ]; then
    printf '%s' "$top"
    return 0
  fi
  pick="$(newest_head_on_line "$line" "$dates")"
  printf '%s' "${pick:-$top}"
}

# metadata_pick_chart <repo> <search_text> [dates] - the chart version to run
# from a per-branch head channel, on stdout. Pure. The repo-scoped grep drops the
# header and any same-named chart from another configured repository.
#
# Such a channel has carried a single chart, so version sort was enough. The
# release team is giving head charts a chart history, at which point sorting a
# commit sha stops meaning anything, so order by the index date when there is
# one and keep the old answer when there is not.
metadata_pick_chart() {
  local repo="${1:?repo required}" search="${2:-}" dates="${3:-}" top
  top="$(printf '%s\n' "$search" \
    | grep "^${repo}/rancher[[:space:]]" \
    | awk '{print $2}' | sort -V | tail -1 | tr -d '[:space:]')"
  resolve_head_pick "$top" "$dates"
}

# metadata_newest_chart - the newest chart in a per-branch head channel, read as
# index rows on stdin. Pure.
#
# Such a channel carries one chart at a time, always a commit-named head, and a
# republish deletes the previous version rather than adding to it. Ordering is by
# index date because a commit sha carries no order; a channel that has no dated
# rows falls back to the release ladder so the answer is still deterministic.
metadata_newest_chart() {
  local entries pick
  entries="$(cat)"
  [ -n "$entries" ] || return 0
  # The line is unknown here, so date-order every head row directly.
  pick="$(printf '%s\n' "$entries" \
    | awk -F'|' '$2 ~ /-head$/ && $3 != "" { print $3 "|" $2 }' \
    | sort -r | head -1 | cut -d'|' -f2)"
  if [ -z "$pick" ]; then
    pick="$(printf '%s\n' "$entries" | cut -d'|' -f2 | highest_version)"
  fi
  printf '%s' "$pick"
}

# metadata_decide_chart_url <image> <tag> <metadata_url> - the chart channel to
# actually use, on stdout.
#
# The metadata is the input, not the last word. muster owns the final decision,
# because the thing being tested is the image and what it bundles, and the image
# states its own chart line in CATTLE_CHART_DEFAULT_BRANCH.
#
# They disagree today for master. The key points at server-charts/release-2.15
# while rancher/rancher:head is built from dev-v2.16, and it has to point
# somewhere, because there is no server-charts/master to derive: chart channels
# are always release-X.Y while the dashboard's top branch is called master. So
# the key is a workaround for a naming mismatch and not a statement that a 2.15
# chart is wanted. Taking the line from the image resolves it without needing
# anything changed upstream, and keeps holding when 2.17 opens and master moves.
#
# Conservative in both directions: the key is kept when the image cannot be read,
# when the two already agree, or when the line's own channel carries no chart.
# MUSTER_CHART_LINE=metadata keeps the key unconditionally, which is how to
# reproduce what the dashboard's own CI deploys.
metadata_decide_chart_url() {
  local image="${1:?image required}" tag="${2:?tag required}" url_meta="${3:?url required}"
  if [ "${MUSTER_CHART_LINE:-image}" = metadata ]; then
    printf '%s' "$url_meta"
    return 0
  fi

  local iline url_line
  iline="$(image_chart_line "$image" "$tag")"
  if [ -z "$iline" ]; then
    printf '%s' "$url_meta"
    return 0
  fi
  url_line="$(metadata_line_chart_url "$iline")"
  if [ "$url_line" = "$url_meta" ]; then
    printf '%s' "$url_meta"
    return 0
  fi

  if [ -z "$(fetch_index_dates_url "$url_line" 2>/dev/null || true)" ]; then
    log_warn "metadata: the image is on the ${iline} line but ${url_line##*/} has no chart; keeping ${url_meta##*/}"
    printf '%s' "$url_meta"
    return 0
  fi

  log_info "metadata: chart line ${iline} taken from the image (${url_line##*/}), not the helm.repo-url key (${url_meta##*/})"
  printf '%s' "$url_line"
}

# helm_resolve_metadata - resolve the server image, chart and tag from the
# dashboard's branches-metadata.json for the branch that RANCHER_IMAGE_TAG names.
#
# This is muster acting as the self-resolving matrix of qa-tasks#2410: the
# registry key in the file decides Prime vs Community, the image keeps the
# branch head tag rather than a chart version, and the chart comes from the
# branch's head channel. Reading the file is deliberate over probing dates or
# registries: which registry a line publishes to is a human decision the
# dashboard team records there (release-2.14 has moved registries repeatedly),
# and no freshness signal can express it.
#
# Exports the same four variables as helm_resolve_version so the install path is
# identical from here on. K3s comes from the same file via branches_apply_k3s_image.
helm_resolve_metadata() {
  local tag="${RANCHER_IMAGE_TAG:?RANCHER_IMAGE_TAG is required}"
  local branch meta facts img itag helmurl milestone reg url repo search
  branch="$(ui_branch_from_tag "$tag" 2>/dev/null || true)"
  [ -n "$branch" ] || die "channel-source metadata: cannot map '$tag' to a branch"

  meta="$(branches_fetch)"
  [ -n "$meta" ] || die "channel-source metadata: branches-metadata.json is unreachable"
  facts="$(printf '%s' "$meta" | branches_parse "$branch")"
  img="$(printf '%s\n' "$facts" | sed -n 's/^RANCHER_IMAGE=//p' | head -1)"
  itag="$(printf '%s\n' "$facts" | sed -n 's/^RANCHER_IMAGE_TAG=//p' | head -1)"
  helmurl="$(printf '%s\n' "$facts" | sed -n 's/^HELM_REPO_URL=//p' | head -1)"
  milestone="$(printf '%s\n' "$facts" | sed -n 's/^MILESTONE_VERSION=//p' | head -1)"
  reg="$(printf '%s\n' "$facts" | sed -n 's/^METADATA_REGISTRY=//p' | head -1)"
  [ -n "$img" ] || die "channel-source metadata: branch '$branch' has no rancher-image in the metadata"
  [ -n "$itag" ] || itag="$tag"

  # The milestone is the statement of intent: it is the release line the branch
  # builds. The helm.repo-url key is a workaround for the fact that channels are
  # always release-X.Y while the top branch is master, so it can point at a line
  # the branch is not on. Prefer the milestone, and keep the image-derived line as
  # an explicit escape hatch (MUSTER_CHART_LINE=image) for a branch whose image
  # says something the file does not.
  local url_meta mline
  url_meta="$(metadata_chart_url "$branch" "$helmurl" "$milestone")"
  mline="$(milestone_chart_line "$milestone")"
  if [ -z "${MUSTER_CHART_LINE:-}" ] && [ -n "$mline" ]; then
    url="$(metadata_line_chart_url "$mline")"
    log_info "metadata: chart line ${mline} taken from the milestone (${url##*/})"
  else
    url="$(metadata_decide_chart_url "$img" "$itag" "$url_meta")"
  fi
  repo="muster-metadata-${url##*/}"
  require_cmd helm
  retry 3 5 "helm repo add $repo" -- helm repo add "$repo" "$url" --force-update
  retry 3 5 "helm repo update" -- helm repo update "$repo"
  search="$(helm_search_charts "$repo")"
  # A head chart is commit-named, so only the index date orders one branch's
  # builds. Every tag here names a branch head, so the ordering always applies.
  local dates=""
  dates="$(fetch_index_dates_url "$url" 2>/dev/null || true)"
  RANCHER_CHART_VERSION="$(metadata_pick_chart "$repo" "$search" "$dates")"
  [ -n "$RANCHER_CHART_VERSION" ] || die "channel-source metadata: no rancher chart at ${url} for ${branch}"

  RANCHER_REPO="$repo"
  RANCHER_CHART_URL="$url"
  RANCHER_IMAGE="$img"
  RANCHER_IMAGE_TAG_RESOLVED="$itag"
  # Empty means Docker Hub, which leaves the image unqualified and gives the
  # post-deploy check nothing to compare. Published either way, so a job can
  # assert the registry the file named.
  METADATA_REGISTRY="$reg"
  RANCHER_CHART_RELEASED="$(printf '%s\n' "$dates" | index_chart_released "$RANCHER_CHART_VERSION" || true)"
  RANCHER_CHART_RELEASED="$(chart_released_date "$RANCHER_CHART_RELEASED")"

  # An explicit image override still wins, the same as the fixed path.
  if [ -n "${RANCHER_IMAGE_TAG_OVERRIDE:-}" ]; then
    local ovr="$RANCHER_IMAGE_TAG_OVERRIDE"
    case "$ovr" in
      */*)
        RANCHER_IMAGE="${ovr%:*}"
        RANCHER_IMAGE_TAG_RESOLVED="${ovr##*:}"
        ;;
      *) RANCHER_IMAGE_TAG_RESOLVED="$ovr" ;;
    esac
    log_info "image overridden: ${RANCHER_IMAGE}:${RANCHER_IMAGE_TAG_RESOLVED} (chart stays $RANCHER_CHART_VERSION)"
  fi

  export RANCHER_REPO RANCHER_CHART_URL RANCHER_IMAGE RANCHER_CHART_VERSION RANCHER_IMAGE_TAG_RESOLVED
  export RANCHER_CHART_RELEASED METADATA_REGISTRY
  log_info "resolved (metadata): branch=$branch registry=${img%%/*} image=${img}:${itag} chart=$RANCHER_CHART_VERSION"
  helm_verify_image
  helm_check_chart_line
}

# helm_recheck_metadata_chart - re-read a metadata row's chart index now that the
# cluster is up, and move to the chart that branch publishes now.
#
# A metadata row runs a floating image, vX.Y-head, which is re-pointed rather
# than replaced, against a chart named for one commit. metadata-release-* keeps
# exactly one chart and a republish deletes the previous version, so the chart
# resolved before provisioning can be gone by the time k3s is up: production
# build #1 resolved 2.14-d3617d27-head at 08:45 and the deploy failed at 08:53
# with "not found in index". Re-reading also settles the quieter half of the same
# mismatch, where the chart survives but names an older commit than the image
# that is about to run.
#
# Best-effort in the same direction as the resolution: an unreadable index leaves
# the earlier pick in place rather than failing a cluster that is already up.
helm_recheck_metadata_chart() {
  local entries pick
  [ -n "${RANCHER_CHART_URL:-}" ] && [ -n "${RANCHER_REPO:-}" ] || return 0
  entries="$(fetch_index_entries_url "$RANCHER_CHART_URL" 2>/dev/null || true)"
  [ -n "$entries" ] || return 0

  # Refresh helm's own cache too, so `helm upgrade --install --version` can see
  # the new chart: the index this function read is not the one helm resolves from.
  retry 3 5 "helm repo update $RANCHER_REPO" -- helm repo update "$RANCHER_REPO" >/dev/null 2>&1 || true

  pick="$(printf '%s\n' "$entries" | metadata_newest_chart)"
  [ -n "$pick" ] || return 0
  [ "$pick" != "${RANCHER_CHART_VERSION:-}" ] || return 0

  log_info "The ${RANCHER_REPO} chart moved while the cluster came up: ${RANCHER_CHART_VERSION} is gone, deploying ${pick} instead"
  RANCHER_CHART_VERSION="$pick"
  RANCHER_CHART_RELEASED="$(printf '%s\n' "$entries" | index_chart_released "$pick" || true)"
  RANCHER_CHART_RELEASED="$(chart_released_date "$RANCHER_CHART_RELEASED")"
  export RANCHER_CHART_VERSION RANCHER_CHART_RELEASED
}

# helm_warn_stopped_community - warn when a fixed Community row names a line that
# has stopped publishing Community releases.
#
# The signal is the newest final Community release being behind the newest final
# Prime one. A rebuilt -head image is not evidence to the contrary: head images
# keep building on both registries after the release line stops, so their date
# proves nothing. The patch gap does. Local runs are deliberate, so this warns
# rather than overriding the caller's channel.
#
# Best-effort: an unreachable index says nothing rather than failing a run that
# was otherwise fine.
helm_warn_stopped_community() {
  [ "${CHANNEL_SOURCE:-fixed}" = fixed ] || return 0
  case "${RANCHER_REPO:-}" in
    rancher-community | rancher-com-*) ;;
    *) return 0 ;;
  esac
  local line comm prime comm_patch prime_patch
  line="$(version_line_of "${RANCHER_IMAGE_TAG:-}")"
  [ -n "$line" ] || return 0

  comm="$(fetch_index_entries rancher-com-rc 2>/dev/null || true)"
  prime="$(fetch_index_entries rancher-prime-ga 2>/dev/null || true)"
  [ -n "$comm" ] && [ -n "$prime" ] || return 0

  comm_patch="$(printf '%s\n' "$comm" | index_line_max_final_patch "$line")"
  prime_patch="$(printf '%s\n' "$prime" | index_line_max_final_patch "$line")"
  case "$comm_patch" in
    '' | *[!0-9-]*) return 0 ;;
  esac
  [ "$comm_patch" -ge 0 ] || return 0
  if [ "$prime_patch" -gt "$comm_patch" ]; then
    log_warn "the ${line} line stopped at Community ${line}.${comm_patch} while Prime is at ${line}.${prime_patch}, so its Community head image may not have been rebuilt in months. Use --channel-source prime, or --channel-source metadata"
  fi
}

# helm_search_charts <repo> - every published version of a repository's rancher
# chart, as `helm search repo` table rows, on stdout.
#
# --max-col-width=0 is what makes the rows usable. helm truncates columns to 50
# characters by default and marks the cut with a literal "...", so a chart named
# after a commit (2.16.0-<40 hex>-head, 55 characters) came back as
# "2.16.0-ff28ae...ee65..." and that string became the chart version and the
# image tag. The install then asked a registry for a tag containing an ellipsis,
# which cannot exist, so any channel whose head builds are commit-tagged failed
# a preflight that looked like a missing image rather than a mangled name.
helm_search_charts() {
  local repo="${1:?repo required}"
  helm search repo "${repo}/rancher" --devel --versions --max-col-width=0 2>/dev/null || true
}

# helm_channel_line_hint <repo> <tag> <search> - explain a miss that is really a
# channel mismatch rather than a missing version, on stdout.
#
# Each Prime channel selects a release shape, so resolving a bare minor filters
# on it. A line that exists in the channel but has not reached that stage yet
# resolves to nothing, and the bare "no chart version matches" is actively
# misleading: the version is right there in the listing, in a shape this channel
# does not select. Say which shapes the line does carry and where to get one.
#
# The filter itself is deliberate and stays: a bare minor means "the newest
# release of that line", and resolving it to a rolling commit build instead would
# quietly change what a pinned CI input installs. What a caller almost always
# wants here is --channel-source prime, which finds the release wherever it is,
# so name that first and the manual channel second.
helm_channel_line_hint() {
  local repo="${1:?repo required}" tag="${2:?tag required}" search="${3:-}"
  local vs filter alt on_line newest
  vs="$(version_string "$tag")"
  case "$repo" in
    rancher-latest)
      filter="release"
      alt="rancher-alpha"
      ;;
    rancher-alpha)
      filter="-alpha"
      alt="rancher-latest"
      ;;
    *) return 0 ;;
  esac

  # Same repository scoping the resolver uses, so this describes what it saw.
  on_line="$(printf '%s\n' "$search" \
    | grep "^${repo}/rancher[[:space:]]" \
    | awk '{print $2}' \
    | grep -E "^${vs//./\\.}([.-]|$)" || true)"
  [ -n "$on_line" ] || return 0

  newest="$(printf '%s\n' "$on_line" | sort -V | tail -3 | tr '\n' ' ')"
  printf 'the %s line is in %s but has no %s chart yet; it carries: %s\n' \
    "$vs" "$repo" "$filter" "$newest"
  printf 'for the newest Prime build of %s try --channel-source prime --version %s, or --repo %s, or pin one of the above with --version\n' \
    "$vs" "$vs" "$alt"
}

# prime_channel_pick <channel> <tag> <entries> [heads] - the newest chart for a
# line in one Prime channel, as "channel|version|created", or nothing. Pure.
#
# Releases and head builds are never mixed. With heads false this is the newest
# release, ignoring head charts: a release stays put while a commit-named chart
# is a new identity on every commit. With heads true it is the newest head chart,
# ordered by publication date because a commit sha carries no order.
prime_channel_pick() {
  local channel="${1:?channel required}" tag="${2:?tag required}" entries="${3:-}"
  local heads="${4:-false}" line raw ver created
  [ -n "$entries" ] || return 0
  line="$(chart_release_line "$(version_string "$tag")")"
  [ -n "$line" ] || return 0

  case "$heads" in
    true)
      raw="$(printf '%s\n' "$entries" | awk -F'|' -v line="$line" "$_MUSTER_VERSION_AWK"'
        $2 != "" && on_line($2, line) && $2 ~ /-head$/ { print $3 "|" $2 }
      ' | sort -t'|' -k1,1 -k2,2 | tail -1 || true)"
      [ -n "$raw" ] || return 0
      created="${raw%%|*}"
      ver="${raw#*|}"
      ;;
    *)
      raw="$(printf '%s\n' "$entries" | awk -F'|' -v line="$line" "$_MUSTER_VERSION_AWK"'
        $2 != "" && on_line($2, line) && $2 !~ /-head$/ { print ladder($2) "|" $2 "|" $3 }
      ' | sort -V -t'|' -k1,1 -k2,2 -k3,3 -k4,4 | tail -1 || true)"
      [ -n "$raw" ] || return 0
      ver="$(printf '%s' "$raw" | cut -d'|' -f4)"
      created="$(printf '%s' "$raw" | cut -d'|' -f5)"
      ;;
  esac

  printf '%s|%s|%s' "$channel" "$ver" "$(chart_created_stamp "$created")"
}

# ga_channel_pick <channel> <tag> <entries> - the newest shipped release for a
# minor in one edition's release channel, as "channel|version|created|appVersion",
# or nothing. Pure.
#
# Separate from prime_channel_pick because a post-release run asks a different
# question. "Newest Prime chart" walks the release ladder, so it answers with a
# candidate the moment the next patch opens: with 2.15.1 shipped, a 2.15.2-alpha1
# outranks it on patch and a row asking for 2.15 would quietly deploy an alpha.
# Here only X.Y.Z counts, so the answer always shipped. A tag naming a full
# version is honoured exactly, which lets a run pin the release it means to test.
# Anything else is not a request this kind can answer: a pre-release tag such as
# 2.14.3-rc1 must not be stripped down to a line request, because that would
# answer with a different chart than the one asked for.
ga_channel_pick() {
  local channel="${1:?channel required}" tag="${2:?tag required}" entries="${3:-}"
  local clean line raw
  [ -n "$entries" ] || return 0
  clean="$(printf '%s' "$tag" | sed 's/^v//')"

  if printf '%s\n' "$clean" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    raw="$(printf '%s\n' "$entries" \
      | awk -F'|' -v want="$clean" '$2 == want { print $2 "|" $3 "|" $4; exit }')"
  elif printf '%s\n' "$clean" | grep -qE '^[0-9]+\.[0-9]+$'; then
    line="$clean"
    raw="$(printf '%s\n' "$entries" | awk -F'|' -v line="$line" "$_MUSTER_VERSION_AWK"'
      $2 != "" && on_line($2, line) && $2 ~ /^[0-9]+[.][0-9]+[.][0-9]+$/ {
        print ladder($2) "|" $2 "|" $3 "|" $4
      }
    ' | sort -V -t'|' -k1,1 -k2,2 -k3,3 -k4,4 | tail -1 | cut -d'|' -f4-6 || true)"
  else
    return 1
  fi

  [ -n "$raw" ] || return 0
  printf '%s|%s' "$channel" "$raw"
}

# best_channel_pick <heads> <pick...> - the highest of the per-channel picks, as
# "channel|version|created|appVersion", or nothing. Pure.
#
# Ordering is the release ladder for releases, so a final release outranks its
# own candidate and a candidate outranks an alpha: that is what makes a line
# which has reached rc resolve to the rc while a line that has not still resolves
# to its newest alpha rather than failing. Head builds are ordered by date, since
# a commit sha carries no order.
best_channel_pick() {
  local heads="${1:-false}"
  shift
  [ "$#" -gt 0 ] || return 0
  if [ "$heads" = true ]; then
    printf '%s\n' "$@" | sort -t'|' -k3,3 -k2,2 | tail -1
  else
    printf '%s\n' "$@" \
      | awk -F'|' "$_MUSTER_VERSION_AWK"' { print ladder($2) "|" $0 }' \
      | sort -V -t'|' -k1,1 -k2,2 -k3,3 -k5,5 | tail -1 | cut -d'|' -f4-
  fi
}

# helm_resolve_prime - pick the channel and chart for a Prime row, rather than
# making the caller pick it.
#
# A Prime row means "the newest Prime release of this line", and that lives in
# whichever of the three Prime channels currently has it: the GA in
# rancher-prime-ga once it ships, an rc in rancher-latest before that, or an
# alpha in rancher-alpha for a line that has not reached rc. Naming one channel
# by hand is wrong in every direction and the wrongness moves as a line
# progresses, so all three are asked and the highest pick wins. The GA channel is
# not optional: charts.optimus stopped receiving final releases at 2.14.3, so the
# pre-release channels alone resolve "newest release" to an rc of a version that
# has shipped.
#
# Release first, head build only as a fallback. rancher-latest also carries
# commit-named head charts, and they are usually the freshest thing published for
# a line, but a head chart is a new identity on every commit: a row resolving to
# one would deploy a different build every run. A minor ships Community first, so
# it has Prime builds for months before its first Prime release, and refusing
# those left the newest minor with no Prime coverage at all. So a minor with a
# release always takes it, and only a minor with none falls back to its newest
# head build. That reverts by itself the day the minor ships.
#
# `prime-head` is the same fallback without the release pick: it always takes the
# newest in-flight build, which is the point of that kind. Both share one code
# path, so they agree on the newest minor for the same reason.
#
# Rewrites RANCHER_REPO and RANCHER_IMAGE_TAG, leaving the normal resolution to
# run against the channel and exact chart that were chosen.
helm_resolve_prime() {
  local kind="${CHANNEL_SOURCE:-prime}"
  local tag="${RANCHER_IMAGE_TAG:?RANCHER_IMAGE_TAG is required}"
  tag_is_bare_minor "$tag" \
    || die "--channel-source ${kind} requires a minor line such as v2.14 (got '$tag')"

  local minor ch entries i heads=false pick="" channel_list rc
  local -a channels=() indexes=() picks=()
  minor="$(version_string "$tag")"
  channel_list="$(printf '%s, ' "${MUSTER_PRIME_CHANNELS[@]}" | sed 's/, $//')"

  # A channel that answers 404 is skipped rather than failing the row: the
  # release team is retiring rancher-alpha, and a row that names a minor rather
  # than a channel should not care. A channel that is unreachable is different:
  # it might hold the newest chart, and resolving from the rest would quietly
  # deploy an older build, so that fails the row here.
  for ch in "${MUSTER_PRIME_CHANNELS[@]}"; do
    rc=0
    entries="$(fetch_index_entries "$ch" 2>/dev/null)" || rc=$?
    if [ "$rc" -ne 0 ]; then
      die "--channel-source ${kind}: failed to fetch chart index from ${ch} ($(repo_url "$ch")/index.yaml)"
    fi
    [ -n "$entries" ] || continue
    channels+=("$ch")
    indexes+=("$entries")
  done
  [ "${#channels[@]}" -gt 0 ] \
    || die "--channel-source ${kind}: none of ${channel_list} served a chart index (every channel answered 404 or was empty); the Prime channels have moved or been retired"

  if [ "$kind" = prime ]; then
    for i in "${!channels[@]}"; do
      pick="$(prime_channel_pick "${channels[i]}" "$minor" "${indexes[i]}" false || true)"
      [ -n "$pick" ] && picks+=("$pick")
    done
  fi
  if [ "${#picks[@]}" -gt 0 ]; then
    pick="$(best_channel_pick false "${picks[@]}")"
  else
    pick=""
  fi

  if [ -z "$pick" ]; then
    heads=true
    picks=()
    for i in "${!channels[@]}"; do
      pick="$(prime_channel_pick "${channels[i]}" "$minor" "${indexes[i]}" true || true)"
      [ -n "$pick" ] && picks+=("$pick")
    done
    if [ "${#picks[@]}" -gt 0 ]; then
      pick="$(best_channel_pick true "${picks[@]}")"
    else
      pick=""
    fi
  fi

  if [ -z "$pick" ]; then
    if [ "$kind" = prime-head ]; then
      die "--channel-source prime-head: no Prime head build for the ${minor} line in ${channel_list}; that minor has no in-flight build published yet"
    fi
    die "--channel-source prime: no Prime release or head build for the ${minor} line in ${channel_list}; that minor is not published to a Prime channel yet"
  fi

  local ver created date
  RANCHER_REPO="$(printf '%s' "$pick" | cut -d'|' -f1)"
  ver="$(printf '%s' "$pick" | cut -d'|' -f2)"
  created="$(printf '%s' "$pick" | cut -d'|' -f3)"
  date="$(chart_released_date "$created")"

  # Staleness gate. A Prime row whose newest chart is months old is testing a
  # line that has stopped publishing there, and a green result would say nothing
  # about anything current. Failing costs nothing, since resolution runs before
  # provisioning. Set MUSTER_PRIME_MAX_AGE_DAYS=0 to accept any age.
  local max_age age
  max_age="${MUSTER_PRIME_MAX_AGE_DAYS:-60}"
  case "$max_age" in
    '' | *[!0-9]*) max_age=60 ;;
  esac
  age="$(date_age_days "$date")"
  if [ "$max_age" -gt 0 ] && [ "$age" -ge 0 ] && [ "$age" -gt "$max_age" ]; then
    die "--channel-source ${kind}: newest ${minor} chart in Prime is ${ver}, published ${date} (${age} days ago, limit ${max_age}). That line has stopped publishing to Prime, so this row would test frozen software. Raise MUSTER_PRIME_MAX_AGE_DAYS (or set 0) to run it anyway"
  fi

  # The chart is named exactly, so the channel's own shape filter cannot exclude
  # it: that is what lets an alpha be selected from rancher-alpha, an rc from
  # rancher-latest and a GA from rancher-prime-ga through one code path.
  RANCHER_IMAGE_TAG="$ver"
  # When the chart was published, which is the only thing a caller needs to
  # decide whether the row is worth running: a Prime row whose newest release has
  # gone quiet is testing a line that has stopped. Exported rather than only
  # logged so a job can read it instead of parsing output.
  RANCHER_CHART_RELEASED="$date"
  if [ "$heads" = true ]; then
    RANCHER_PRIME_HEAD_PICK=1
    # A head pick rewrites the tag to a chart version, and the dashboard branch
    # is normally read off that tag: for a release 2.15.1 belongs to
    # release-2.15. For a head build of a minor with no release it is wrong,
    # because that minor is still built on master and has no release branch cut
    # yet: 2.16.0-<sha>-head would send the run to a release-2.16 that does not
    # exist. The metadata file says which branch builds which minor, so ask it
    # rather than assuming. Best-effort: offline, or with no answer, the
    # mechanical mapping is still better than nothing.
    local meta dbranch=""
    DASHBOARD_BRANCH_RESOLVED=""
    if command -v branches_fetch >/dev/null 2>&1; then
      meta="$(branches_fetch 2>/dev/null || true)"
      if [ -n "$meta" ]; then
        dbranch="$(printf '%s' "$meta" | branches_for_milestone_line "$minor" 2>/dev/null || true)"
      fi
    fi
    DASHBOARD_BRANCH_RESOLVED="${dbranch:-release-${minor}}"
    export DASHBOARD_BRANCH_RESOLVED
  else
    RANCHER_PRIME_HEAD_PICK=0
  fi
  export RANCHER_REPO RANCHER_IMAGE_TAG RANCHER_CHART_RELEASED RANCHER_PRIME_HEAD_PICK

  if [ "$heads" = true ]; then
    log_info "prime: newest ${minor} HEAD BUILD is ${ver} in ${RANCHER_REPO}, published ${created} (no Prime release for this minor yet, so this will differ on the next run); it is built on dashboard branch ${DASHBOARD_BRANCH_RESOLVED}"
  else
    log_info "prime: newest ${minor} release is ${ver} in ${RANCHER_REPO}, published ${created} (head builds are used only when a minor has no release)"
  fi
}

# helm_resolve_ga - resolve a shipped release for a post-release row.
#
# A prime: row walks the release ladder, so with 2.15.1 shipped it returns
# 2.15.2-alpha1 the day that patch opens, and a head build for a minor with no
# release at all. That is right for the weekly rc and alpha pass and wrong for
# verifying a release that just went out. A GA row reads one edition's release
# channel and only final X.Y.Z, so the answer always shipped, and it accepts a
# full version as well, which is how a run pins the release it means to test.
#
# Neither the image tag nor the registry is overridden beyond naming the chart:
# a released chart supplies its own image through appVersion, so the chart is
# asked for by version and the image tag follows it. Setting the image tag from
# the chart version instead asks Docker Hub for a tag that was never published.
helm_resolve_ga() {
  local kind="${CHANNEL_SOURCE:?CHANNEL_SOURCE is required}"
  local channel="${MUSTER_GA_CHANNEL[$kind]:-}"
  [ -n "$channel" ] || die "unknown --channel-source '$kind' for a GA row"
  local tag="${RANCHER_IMAGE_TAG:?RANCHER_IMAGE_TAG is required}"
  local entries pick ver created date app want

  entries="$(fetch_index_entries "$channel" 2>/dev/null || true)"
  [ -n "$entries" ] \
    || die "--channel-source ${kind}: ${channel} served no chart index; the GA channel may have moved"

  # Only two shapes name a shipped release: a minor to walk, or one version to
  # take exactly. A pre-release tag names neither, and stripping its suffix into
  # a line request would answer with a different chart than the one asked for.
  want="$(printf '%s' "$tag" | sed 's/^v//')"
  printf '%s\n' "$want" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
    || die "--channel-source ${kind} takes a minor line such as v2.15 or a full version such as v2.15.1 (got '$tag')"

  pick="$(ga_channel_pick "$channel" "$tag" "$entries" || true)"
  if [ -z "$pick" ]; then
    if printf '%s\n' "$want" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
      die "--channel-source ${kind}: ${channel} publishes no final release ${want}. A GA row takes a shipped X.Y.Z chart, taken exactly when a full version is named; use --channel-source prime for a pre-release or head build"
    fi
    die "--channel-source ${kind}: ${channel} publishes no final release on the ${want} line. That minor has no shipped chart in this edition; use --channel-source prime for a pre-release or head build"
  fi

  ver="$(printf '%s' "$pick" | cut -d'|' -f2)"
  created="$(printf '%s' "$pick" | cut -d'|' -f3)"
  app="$(printf '%s' "$pick" | cut -d'|' -f4)"
  date="$(chart_released_date "$created")"

  # The deploy names the image tag, so it, not the chart, decides which image is
  # pulled. That is only safe while it matches the chart's own appVersion: a
  # chart that numbered its image differently would pull a tag that was never
  # published and the pods would sit in ImagePullBackOff with nothing naming the
  # cause. The value is taken as written, so it must be exactly v<version>; an
  # empty appVersion is tolerated, and nothing else is.
  if [ -n "$app" ]; then
    [ "$app" = "v$ver" ] \
      || die "--channel-source ${kind}: chart ${ver} declares appVersion '${app}', but this row reports having deployed v${ver}. The chart numbers its image differently from its own version"
  fi

  RANCHER_REPO="$channel"
  RANCHER_CHART_URL="$(repo_url "$channel")"
  RANCHER_IMAGE="$(repo_image "$channel")"
  RANCHER_CHART_VERSION="$ver"
  RANCHER_IMAGE_TAG="v$ver"
  RANCHER_IMAGE_TAG_RESOLVED="v$ver"
  RANCHER_CHART_RELEASED="$date"
  RANCHER_IMAGE_TAG_FROM_CHART=1
  # An explicit --image-tag is still an override, and then the tag must be sent:
  # the chart's appVersion is no longer what the run means to test.
  if [ -n "${RANCHER_IMAGE_TAG_OVERRIDE:-}" ]; then
    local ovr="$RANCHER_IMAGE_TAG_OVERRIDE"
    case "$ovr" in
      */*)
        RANCHER_IMAGE="${ovr%:*}"
        RANCHER_IMAGE_TAG_RESOLVED="${ovr##*:}"
        ;;
      *) RANCHER_IMAGE_TAG_RESOLVED="$ovr" ;;
    esac
    RANCHER_IMAGE_TAG_FROM_CHART=0
    log_info "image overridden: ${RANCHER_IMAGE}:${RANCHER_IMAGE_TAG_RESOLVED} (chart stays $RANCHER_CHART_VERSION)"
  fi

  require_cmd helm
  retry 3 5 "helm repo add $channel" -- \
    helm repo add "$channel" "$RANCHER_CHART_URL" --force-update
  retry 3 5 "helm repo update" -- helm repo update "$channel"

  export RANCHER_REPO RANCHER_CHART_URL RANCHER_IMAGE RANCHER_CHART_VERSION \
    RANCHER_IMAGE_TAG RANCHER_IMAGE_TAG_RESOLVED RANCHER_CHART_RELEASED \
    RANCHER_IMAGE_TAG_FROM_CHART
  log_info "resolved (${kind}): ${ver} in ${channel}, published ${date} (shipped releases only, so a newer rc, alpha or head build is deliberately ignored)"
  helm_verify_image
  helm_check_chart_line
}

# helm_resolve_version - orchestrate the impure resolution against a live helm.
# Validates RANCHER_REPO, adds/updates the repo, runs the search, and exports:
#   RANCHER_CHART_URL RANCHER_IMAGE RANCHER_CHART_VERSION RANCHER_IMAGE_TAG_RESOLVED
# It also exports RANCHER_CHART_RELEASED when the index could be read, which is
# what lets a job drop a row whose line has stopped publishing.
helm_resolve_version() {
  case "${CHANNEL_SOURCE:-fixed}" in
    metadata)
      helm_resolve_metadata
      return
      ;;
    # A GA row reads the index and the chart alone, so there is no helm search to
    # do afterwards: the chart is named by version and supplies its own image tag.
    prime-ga | community-ga)
      helm_resolve_ga
      return
      ;;
    prime | prime-head)
      # A resolved Prime pick is already an exact chart version, so the keep-fresh
      # probe must not run afterwards: it would rewrite the pick.
      helm_resolve_prime
      ;;
    *)
      freshness_maybe_promote
      # A fixed Community row keeps whatever channel it was given, so warn rather
      # than override when that line has stopped publishing there.
      helm_warn_stopped_community
      ;;
  esac
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
  search="$(helm_search_charts "$repo")"
  # A head chart is commit-named, so version sort cannot order one line's builds
  # and only the index date can. Fetched for `head` alone, the one tag that has
  # to choose between them.
  local dates=""
  [ "$tag" = head ] && dates="$(fetch_index_dates "$repo" 2>/dev/null || true)"
  RANCHER_CHART_VERSION="$(resolve_chart_version "$repo" "$tag" "$search" "$dates" || true)"
  if [ -z "$RANCHER_CHART_VERSION" ]; then
    local available why line_hint
    line_hint="$(helm_channel_line_hint "$repo" "$tag" "$search" || true)"
    why="$(helm_missing_tag_hint "${RANCHER_IMAGE:-rancher/rancher}" "$tag" || true)"
    if [ -n "$line_hint" ]; then
      # The line is present and the channel shape is what excluded it, so the
      # newest charts overall would only point away from the real answer.
      while IFS= read -r l; do
        [ -n "$l" ] && log_err "$l"
      done <<<"$line_hint"
    else
      available="$(printf '%s\n' "$search" \
        | grep "^${repo}/rancher[[:space:]]" \
        | awk '{print $2}' | sort -V | tail -5 | tr '\n' ' ')"
      [ -n "$available" ] && log_err "newest in ${repo}: ${available}"
    fi
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
  # When the chart was published, so a fixed row reports it too rather than only
  # a Prime row. Reuses the index the head path already fetched.
  if [ -z "${RANCHER_CHART_RELEASED:-}" ]; then
    if [ -n "$dates" ]; then
      RANCHER_CHART_RELEASED="$(printf '%s\n' "$dates" | index_chart_released "$RANCHER_CHART_VERSION" || true)"
    else
      RANCHER_CHART_RELEASED="$(fetch_index_entries "$repo" 2>/dev/null \
        | index_chart_released "$RANCHER_CHART_VERSION" || true)"
    fi
    RANCHER_CHART_RELEASED="$(chart_released_date "$RANCHER_CHART_RELEASED")"
  fi
  export RANCHER_CHART_URL RANCHER_IMAGE RANCHER_CHART_VERSION RANCHER_IMAGE_TAG_RESOLVED
  export RANCHER_CHART_RELEASED
  log_info "resolved: repo=$repo chart=$RANCHER_CHART_VERSION image=${RANCHER_IMAGE:-rancher/rancher} tag=$RANCHER_IMAGE_TAG_RESOLVED"
  helm_verify_image
  helm_check_chart_line
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

  # A metadata row deploys against a single-slot per-branch chart channel, so the
  # chart resolved before provisioning can be gone by now. Re-read before helm is
  # handed a version it may no longer be able to fetch.
  if [ "${CHANNEL_SOURCE:-fixed}" = metadata ]; then
    helm_recheck_metadata_chart
  fi

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
    --set "replicas=${RANCHER_REPLICAS:-1}"
    --set "rancherImage=${image}"
    --set "rancherImagePullPolicy=Always"
    --set "bootstrapPassword=${RANCHER_PASSWORD:-password1234}"
    --set "ingress.ingressClassName=traefik"
    --set "extraEnv[0].name=CATTLE_AGENT_IMAGE"
    --set-string "extraEnv[0].value=${agent_image}:${tag}"
  )
  # A released chart names its own image tag in appVersion, and every GA chart
  # numbers it v<chart version>. Sending rancherImageTag as well would override
  # that with a value derived the same way today, but it would silently keep
  # working if a chart ever numbered its image differently, pulling a tag that
  # was never published. Leave the decision to the chart when the chart is what
  # named the image.
  if ! is_true "${RANCHER_IMAGE_TAG_FROM_CHART:-}"; then
    args+=(--set "rancherImageTag=${tag}")
  fi
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
  elif [ -n "${MUSTER_UI_OFFLINE:-}" ]; then
    # true | false | auto deploy as the env var Rancher reads at start; `auto`
    # deploys as true and gates_reconcile_ui_offline may flip it once the running
    # pod says which UI the image embeds. dynamic emits nothing, which leaves the
    # chart/Rancher default in place.
    local ui_preferred="$MUSTER_UI_OFFLINE"
    case "$ui_preferred" in
      auto) ui_preferred=true ;;
      dynamic) ui_preferred="" ;;
    esac
    if [ -n "$ui_preferred" ]; then
      args+=(
        --set "extraEnv[1].name=CATTLE_UI_OFFLINE_PREFERRED"
        --set-string "extraEnv[1].value=${ui_preferred}"
      )
    fi
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
