#!/usr/bin/env bash
# lib/node.sh - provision the Node runtime a dashboard build needs.
#
# The Node major a dist must build with is dictated by the checked-out branch,
# not the host. rancher/dashboard pins it in `.nvmrc` (master -> 24,
# release-2.14 -> 20); `engines.node` is the fallback floor. Matching only the
# floor is not enough: a newer host Node satisfies `>=20` yet breaks the
# release-2.14 build (a transitive dependency rejects Node 24). So muster
# targets the exact major the branch declares.
#
# When the host Node already is that major, it is used as-is. Otherwise muster
# downloads a pinned-by-checksum Node into its cache (verified against
# nodejs.org's official SHASUMS256.txt, fail-closed) and a matching yarn
# classic, then runs the build with that toolchain on PATH. Nothing is written
# outside the cache and the host Node is never touched.
#
# Pure helpers (no network, no writes) are split out for unit testing; only
# node_resolve_version and node_ensure touch the network or filesystem.

[ -n "${_MUSTER_LIB_NODE_SH:-}" ] && return 0
_MUSTER_LIB_NODE_SH=1

# Yarn classic pinned to the same version the container image ships, so a
# provisioned host toolchain matches the containerized one byte-for-byte in
# intent. yarn is a Node script, so any Node major runs it.
MUSTER_YARN_VERSION="${MUSTER_YARN_VERSION:-1.22.22}"

# --- pure helpers (unit-tested) ----------------------------------------------

# node_parse_nvmrc <content> - the Node major declared by an .nvmrc file.
# Pure: "20" -> 20, "v20.10.0" -> 20, "20.10.0" -> 20. Non-numeric pins
# (e.g. "lts/iron") and empty input print nothing so the caller can fall back.
node_parse_nvmrc() {
  local v="${1:-}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  v="${v#v}"
  case "$v" in
    [0-9]*) printf '%s' "${v%%.*}" ;;
    *) return 0 ;;
  esac
}

# node_platform_tag <uname-s> <uname-m> - the nodejs.org artifact platform tag
# (e.g. darwin-arm64, linux-x64). Pure. Returns 1 for an unsupported platform.
node_platform_tag() {
  local s="${1:-}" m="${2:-}" os arch
  case "$s" in
    Darwin) os=darwin ;;
    Linux) os=linux ;;
    *) return 1 ;;
  esac
  case "$m" in
    x86_64 | amd64) arch=x64 ;;
    arm64 | aarch64) arch=arm64 ;;
    *) return 1 ;;
  esac
  printf '%s-%s' "$os" "$arch"
}

# node_pick_latest <major> - read a nodejs.org index.tab on stdin and print the
# newest full version (e.g. v20.14.0) whose major matches. Pure. The index is
# sorted newest-first, so the first prefix match wins. The trailing dot guards
# against a shorter major matching a longer one (v2. never matches v20.).
node_pick_latest() {
  local major="${1:?major required}"
  awk -v p="v${major}." 'NR > 1 && substr($1, 1, length(p)) == p { print $1; exit }'
}

# --- network + filesystem ----------------------------------------------------

# node_cache_dir - where provisioned Node toolchains live.
node_cache_dir() { printf '%s/muster/node' "${XDG_CACHE_HOME:-$HOME/.cache}"; }

# node_target_major <src> - the Node major the checkout declares: .nvmrc first
# (the precise upstream pin), then the engines.node floor. Prints nothing when
# neither is present so the caller keeps the host Node.
node_target_major() {
  local src="${1:?src required}" m
  if [ -r "$src/.nvmrc" ]; then
    m="$(node_parse_nvmrc "$(cat "$src/.nvmrc")")"
    [ -n "$m" ] && {
      printf '%s' "$m"
      return 0
    }
  fi
  engines_min_major "$(ui_engines_node "$src")"
}

# node_resolve_version <major> - the latest released Node version for a major,
# from nodejs.org's index. Network. Returns 1 if it cannot be resolved.
node_resolve_version() {
  local major="${1:?major required}" tmp ver
  tmp="$(mktemp)"
  if ! dv_fetch "https://nodejs.org/dist/index.tab" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  ver="$(node_pick_latest "$major" <"$tmp")"
  rm -f "$tmp"
  [ -n "$ver" ] || return 1
  printf '%s' "$ver"
}

# node_ensure_yarn <bindir> - make yarn classic available alongside a
# provisioned Node, installed into the same prefix so it runs under that Node.
node_ensure_yarn() {
  local bin="${1:?bindir required}"
  [ -x "$bin/yarn" ] && return 0
  log_info "installing yarn ${MUSTER_YARN_VERSION} into the provisioned Node"
  PATH="$bin:$PATH" "$bin/npm" install -g "yarn@${MUSTER_YARN_VERSION}" \
    >/dev/null 2>&1 || die "failed to install yarn into the provisioned Node"
}

# node_ensure <major> - ensure a Node of <major> (plus yarn) exists in the
# cache and print its bin directory. Downloads and checksum-verifies against
# nodejs.org's SHASUMS256.txt (fail-closed) on a cache miss; reuses otherwise.
node_ensure() {
  local major="${1:?major required}" plat ver dir tarname url tarball tmp
  plat="$(node_platform_tag "$(uname -s)" "$(uname -m)")" \
    || die "no prebuilt Node for this platform ($(uname -s)/$(uname -m)); set NODE_BIN"
  ver="$(node_resolve_version "$major")" \
    || die "could not resolve a Node $major release from nodejs.org"
  dir="$(node_cache_dir)/node-${ver}-${plat}"
  if [ -x "$dir/bin/node" ]; then
    node_ensure_yarn "$dir/bin"
    printf '%s' "$dir/bin"
    return 0
  fi
  tarname="node-${ver}-${plat}.tar.gz"
  url="https://nodejs.org/dist/${ver}/${tarname}"
  mkdir -p "$(node_cache_dir)"
  log_info "provisioning Node ${ver} (${plat}) into the muster cache"
  tarball="$(
    DV_URL="$url" \
      DV_DEST="$(node_cache_dir)/${tarname}" \
      DV_FORMAT="github_sha256sum" \
      DV_CHECKSUM_URL="https://nodejs.org/dist/${ver}/SHASUMS256.txt" \
      DV_ARTIFACT_NAME="$tarname" \
      download_verify
  )" || die "Node download failed to verify"
  tmp="$(mktemp -d "$(node_cache_dir)/.extract.XXXXXX")"
  tar -xzf "$tarball" -C "$tmp" --strip-components=1 \
    || die "failed to extract $tarname"
  rm -rf "$dir"
  mv "$tmp" "$dir"
  rm -f "$tarball"
  node_ensure_yarn "$dir/bin"
  printf '%s' "$dir/bin"
}

# ui_resolve_node <src> - the bin directory to prepend to PATH for a dashboard
# build, or nothing to use the host Node. An explicit NODE_BIN wins (escape
# hatch). Otherwise the target major is derived from the checkout; the host
# Node is reused when it already is that major, else one is provisioned.
ui_resolve_node() {
  local src="${1:?src required}" major
  if [ -n "${NODE_BIN:-}" ]; then
    if [ -d "$NODE_BIN" ] && [ -x "$NODE_BIN/node" ]; then
      printf '%s' "$NODE_BIN"
    elif [ -x "$NODE_BIN" ]; then
      dirname "$NODE_BIN"
    else
      die "--node-bin '$NODE_BIN' is not a Node binary or a directory containing one"
    fi
    return 0
  fi
  major="$(node_target_major "$src")"
  if [ -z "$major" ]; then
    log_warn "no .nvmrc or engines.node in '$src'; using the host Node"
    return 0
  fi
  if command -v node >/dev/null 2>&1 \
    && [ "$(node_major "$(node --version)")" = "$major" ]; then
    log_info "host node $(node --version) matches the target major ($major)"
    return 0
  fi
  log_info "dashboard branch wants Node $major; provisioning it"
  node_ensure "$major"
}
