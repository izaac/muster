#!/usr/bin/env bash
# lib/download.sh - download an artifact only if its SHA256 matches.
#
# Ported from qa-infra-automation roles/download_verify. Verification is
# mandatory and fail-closed: an empty, malformed, or mismatched checksum aborts
# the download rather than installing an unverified artifact. Four ways to learn
# the expected checksum:
#
#   inline           caller pins the sha256 in source (strongest; deterministic)
#   sha256_file      a one-line "<sha>  <name>" file; take field 1
#   github_sha256sum a multi-line checksums file; match the line for <name>
#   github_release   resolve the sha256 from a GitHub release asset by tag
#                    (the "digest" field), cached on disk to avoid repeat API
#                    calls for the same tag+asset
#
# The verification logic is split into pure helpers (no network, no filesystem
# writes) so it can be unit-tested exhaustively; only dv_fetch and the
# download_verify orchestrator touch the network.

[ -n "${_MUSTER_DOWNLOAD_SH:-}" ] && return 0
_MUSTER_DOWNLOAD_SH=1

# --- pure helpers (unit-tested) ----------------------------------------------

# dv_normalize_sha <value> - print a canonical sha256 (lowercase, no surrounding
# whitespace) on stdout and return 0, or print nothing and return 1 if the value
# is not exactly 64 hex characters. This is the fail-closed gate every checksum
# passes through: garbage, truncation, and the empty string all become failures.
dv_normalize_sha() {
  local v
  v="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    *[!0-9a-f]*) return 1 ;;
  esac
  [ "${#v}" -eq 64 ] || return 1
  printf '%s' "$v"
}

# dv_sha_from_file <checksum_file> - first whitespace-delimited field of the
# first line, for single-artifact ".sha256" / "sha256sum_file" formats.
dv_sha_from_file() {
  [ -r "${1:-}" ] || return 1
  awk 'NR==1{print $1; exit}' "$1"
}

# dv_sha_from_list <checksum_file> <artifact_name> - the checksum on the line
# whose second field is exactly <artifact_name>, for multi-artifact checksums
# files (e.g. cloudflare/cloudflared sha256sum-amd64.txt). Anchored so that a
# name which is a suffix of another entry cannot match the wrong line.
dv_sha_from_list() {
  local file="${1:-}" name="${2:-}"
  [ -r "$file" ] && [ -n "$name" ] || return 1
  awk -v n="$name" '$2==n{print $1; exit}' "$file"
}

# dv_sha_from_gh_json <release_json> <asset_name> - extract the sha256 of a
# release asset from the GitHub releases API JSON. Modern asset objects carry a
# "digest":"sha256:<hex>" field; this matches the asset by name and returns its
# digest without requiring jq. Pure: operates on an already-fetched file.
dv_sha_from_gh_json() {
  local file="${1:-}" name="${2:-}"
  [ -r "$file" ] && [ -n "$name" ] || return 1
  tr ',' '\n' <"$file" \
    | awk -v n="\"name\":\"${name}\"" '
        index($0, n) { found=1; next }
        found && /"name":"/ { exit }
        found && match($0, /"digest":"sha256:[0-9a-f]+"/) {
          s = substr($0, RSTART, RLENGTH)
          sub(/.*sha256:/, "", s); sub(/"$/, "", s)
          print s; exit
        }'
}

# dv_check <actual> <expected> - succeed only when both normalize to the same
# valid sha256. Either side empty or malformed is a failure (fail-closed).
dv_check() {
  local a b
  a="$(dv_normalize_sha "${1:-}")" || return 1
  b="$(dv_normalize_sha "${2:-}")" || return 1
  [ "$a" = "$b" ]
}

# --- network + filesystem (thin; mocked in tests) ----------------------------

# dv_fetch <url> <dest> - download to <dest>, honouring a discovered CA bundle.
# Overridable in tests by redefining the function before calling download_verify.
dv_fetch() {
  local url="$1" dest="$2" ca
  local args=(-fsSL -o "$dest")
  ca="$(ca_bundle)"
  [ -n "$ca" ] && args+=(--cacert "$ca")
  curl "${args[@]}" "$url"
}

# dv_github_release_json <repo> <tag> <dest> - fetch release metadata for a tag.
dv_github_release_json() {
  local repo="$1" tag="$2" dest="$3" ca
  local args=(-fsSL -H "Accept: application/vnd.github+json" -o "$dest")
  ca="$(ca_bundle)"
  [ -n "$ca" ] && args+=(--cacert "$ca")
  [ -n "${GITHUB_TOKEN:-}" ] && args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  curl "${args[@]}" "https://api.github.com/repos/${repo}/releases/tags/${tag}"
}

# dv_cache_dir - where verified github_release checksums are remembered.
dv_cache_dir() { printf '%s/muster' "${XDG_CACHE_HOME:-$HOME/.cache}"; }

# dv_resolve_expected - print the expected sha256 for the requested format,
# fetching any checksum metadata it needs. Reads DV_* variables set by the
# caller (see download_verify). Returns 1 if it cannot obtain a valid checksum.
dv_resolve_expected() {
  local tmp expected=''
  case "${DV_FORMAT:?DV_FORMAT is required}" in
    inline)
      expected="${DV_SHA256:-}"
      ;;
    sha256_file)
      tmp="$(mktemp)"
      if dv_fetch "${DV_CHECKSUM_URL:?DV_CHECKSUM_URL required}" "$tmp"; then
        expected="$(dv_sha_from_file "$tmp")"
      fi
      rm -f "$tmp"
      ;;
    github_sha256sum)
      tmp="$(mktemp)"
      if dv_fetch "${DV_CHECKSUM_URL:?DV_CHECKSUM_URL required}" "$tmp"; then
        expected="$(dv_sha_from_list "$tmp" "${DV_ARTIFACT_NAME:?DV_ARTIFACT_NAME required}")"
      fi
      rm -f "$tmp"
      ;;
    github_release)
      expected="$(dv_resolve_github_release)"
      ;;
    *)
      die "download_verify: unknown DV_FORMAT '$DV_FORMAT'"
      ;;
  esac
  dv_normalize_sha "$expected"
}

# dv_resolve_github_release - print the cached or freshly fetched asset sha256.
dv_resolve_github_release() {
  local repo="${DV_GITHUB_REPO:?DV_GITHUB_REPO required}"
  local tag="${DV_GITHUB_TAG:?DV_GITHUB_TAG required}"
  local asset="${DV_ARTIFACT_NAME:?DV_ARTIFACT_NAME required}"
  local cache sha tmp
  cache="$(dv_cache_dir)/${repo//\//_}_${tag}_${asset}.sha256"
  if [ -r "$cache" ]; then
    cat "$cache"
    return 0
  fi
  tmp="$(mktemp)"
  if dv_github_release_json "$repo" "$tag" "$tmp"; then
    sha="$(dv_sha_from_gh_json "$tmp" "$asset")"
  fi
  rm -f "$tmp"
  sha="$(dv_normalize_sha "$sha")" || return 1
  mkdir -p "$(dv_cache_dir)"
  printf '%s' "$sha" >"$cache"
  printf '%s' "$sha"
}

# download_verify - fetch DV_URL to DV_DEST, verify its SHA256, abort on any
# mismatch. Caller sets DV_* before invoking:
#   DV_URL DV_DEST DV_FORMAT                 (always)
#   DV_SHA256                                (inline)
#   DV_CHECKSUM_URL [DV_ARTIFACT_NAME]       (sha256_file / github_sha256sum)
#   DV_GITHUB_REPO DV_GITHUB_TAG DV_ARTIFACT_NAME  (github_release)
# A previously verified DV_DEST is reused when its checksum still matches.
download_verify() {
  local url="${DV_URL:?DV_URL is required}"
  local dest="${DV_DEST:?DV_DEST is required}"
  local expected got tmp
  expected="$(dv_resolve_expected)" \
    || die "download_verify: could not obtain a valid SHA256 for $(basename "$dest")"

  if [ -e "$dest" ] && got="$(dv_file_sha "$dest")" && dv_check "$got" "$expected"; then
    log_info "verified (cached): $(basename "$dest")"
    printf '%s\n' "$dest"
    return 0
  fi

  tmp="$(mktemp "${dest}.XXXX")"
  if ! dv_fetch "$url" "$tmp"; then
    rm -f "$tmp"
    die "download_verify: download failed: $url"
  fi
  got="$(dv_file_sha "$tmp")"
  if ! dv_check "$got" "$expected"; then
    rm -f "$tmp"
    die "download_verify: SHA256 mismatch for $(basename "$dest") (expected $expected, got ${got:-none})"
  fi
  chmod "${DV_MODE:-0644}" "$tmp"
  mv -f "$tmp" "$dest"
  log_ok "verified: $(basename "$dest") ($expected)"
  printf '%s\n' "$dest"
}

# dv_file_sha <file> - SHA256 of a local file, or nothing if it is unreadable.
dv_file_sha() {
  [ -r "${1:-}" ] || return 1
  sha256sum "$1" | awk '{print $1}'
}
