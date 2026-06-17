#!/usr/bin/env bash
# lib/buildui.sh - build a Rancher dashboard UI dist from a source branch.
#
# Quarantined helper for the `build-ui` verb. The core `up` flow never builds a
# UI; it only mounts a dist someone hands it. This file owns all the dashboard
# build knowledge so that concern stays out of the provider-blind core.
#
# The branch a dist is built from must match the Rancher image version line:
#   head        -> master            (newest minor is still on master)
#   v2.14-head  -> release-2.14
#   2.14.2-rc1  -> release-2.14
# When a derived release branch does not exist yet (a brand-new minor that is
# still master upstream) we fall back to master.
#
# The actual production build is delegated to the dashboard repo's own
# scripts/build-e2e (yarn install + yarn build with ROUTER_BASE=/dashboard/),
# so muster carries no yarn/webpack knowledge and stays a thin orchestrator.

[ -n "${_MUSTER_LIB_BUILDUI_SH:-}" ] && return 0
_MUSTER_LIB_BUILDUI_SH=1

# ui_branch_from_tag <tag> - the dashboard branch a Rancher image tag maps to.
# Pure: head -> master, otherwise release-<major.minor>. Strips a pre-release
# suffix and an optional leading "v" exactly like helm.sh version_string.
ui_branch_from_tag() {
  local tag="${1:?tag required}" v="${1%%-*}"
  v="${v#v}"
  if [ "$tag" = "head" ] || [ "$v" = "head" ]; then
    printf 'master'
    return 0
  fi
  case "$v" in
    [0-9]*.[0-9]*)
      printf 'release-%s' "$(printf '%s' "$v" | cut -d. -f1,2)"
      ;;
    *) die "cannot derive a dashboard branch from tag '$tag'" ;;
  esac
}

# engines_min_major <engines> - the minimum Node major from a package.json
# engines.node range. Pure: ">=24.0.0" -> 24, "^20.10.0" -> 20, "" -> "".
engines_min_major() {
  printf '%s' "${1:-}" | grep -oE '[0-9]+' | head -1
}

# node_major <node --version output> - the major from "v24.3.1" -> 24. Pure.
node_major() {
  printf '%s' "${1#v}" | cut -d. -f1
}

# ui_engines_node <src> - read engines.node from <src>/package.json. Impure
# (reads a file); prints the raw range (empty if none declared).
ui_engines_node() {
  local pj="${1:?src required}/package.json"
  [ -f "$pj" ] || die "no package.json in '$1' (wrong --dashboard-src?)"
  grep -A3 '"engines"' "$pj" | grep '"node"' | head -1 \
    | sed -E 's/.*"node":[[:space:]]*"([^"]*)".*/\1/'
}

# ui_resolve_branch <src> <tag> - derive the wanted branch and fall back to
# master when a release branch does not exist yet (newest minor still master).
ui_resolve_branch() {
  local src="${1:?src required}" tag="${2:?tag required}" want
  want="$(ui_branch_from_tag "$tag")"
  if [ "$want" != "master" ] \
    && ! git -C "$src" rev-parse --verify --quiet "refs/remotes/origin/${want}" >/dev/null 2>&1 \
    && ! git -C "$src" rev-parse --verify --quiet "refs/heads/${want}" >/dev/null 2>&1; then
    log_warn "dashboard branch '$want' does not exist; falling back to master"
    want="master"
  fi
  printf '%s' "$want"
}

# ui_node_gate <src> - fail clearly when the active Node is too old for the
# checked-out branch. muster does not install Node (a consumer/toolchain
# concern); it only refuses to run a build that would fail late.
ui_node_gate() {
  local src="${1:?src required}" eng min cur
  eng="$(ui_engines_node "$src")"
  min="$(engines_min_major "$eng")"
  [ -n "$min" ] || return 0
  require_cmd node "enter the devenv shell or install Node >= ${min}"
  cur="$(node_major "$(node --version)")"
  if [ "$cur" -lt "$min" ]; then
    die "dashboard build needs Node >= ${min} (engines '${eng}'); have $(node --version)"
  fi
  log_info "node $(node --version) satisfies engines '${eng}'"
}

# buildui_run - the `build-ui` verb. Resolves the branch from RANCHER_IMAGE_TAG,
# checks it out (unless the tree is dirty, in which case it builds as-is so a
# developer can test uncommitted code), gates Node, and delegates to the
# dashboard repo's build-e2e. Prints the absolute dist path on stdout.
buildui_run() {
  local src="${DASHBOARD_SRC:-}"
  [ -n "$src" ] || die "build-ui needs --dashboard-src <rancher/dashboard checkout>"
  [ -d "$src/.git" ] || die "--dashboard-src '$src' is not a git checkout"
  [ -f "$src/scripts/version" ] || die "'$src' has no scripts/version (not rancher/dashboard?)"
  require_cmd git
  require_cmd yarn "enter the devenv shell"

  local branch dist cur
  branch="$(ui_resolve_branch "$src" "$RANCHER_IMAGE_TAG")"
  dist="${DASHBOARD_DIST:-$src/dist}"
  cur="$(git -C "$src" rev-parse --abbrev-ref HEAD)"

  if [ -n "$(git -C "$src" status --porcelain)" ]; then
    log_warn "dashboard-src is dirty; building the working tree as-is (on '$cur', wanted '$branch')"
  elif [ "$cur" != "$branch" ]; then
    log_info "build-ui: tag=$RANCHER_IMAGE_TAG -> dashboard branch '$branch'"
    retry 3 5 "git fetch $branch" -- git -C "$src" fetch --quiet origin "$branch"
    git -C "$src" checkout --quiet "$branch"
    git -C "$src" reset --hard --quiet "origin/${branch}"
  else
    log_info "build-ui: already on dashboard branch '$branch'"
  fi

  ui_node_gate "$src"

  # Run the dashboard production build directly rather than scripts/build-e2e:
  # build-e2e additionally pulls the legacy ember UI (rancher/ui) from a CDN,
  # which is network-fragile and is not part of the dashboard dist we mount.
  # A fresh bash avoids inheriting muster's `set -u` (scripts/version reads
  # unset vars) and sidesteps the script's /bin/bash shebang under devenv.
  log_info "building dashboard dist -> $dist"
  bash -e -c '
    cd "$1"
    yarn install --frozen-lockfile
    # shellcheck disable=SC1091
    source scripts/version
    COMMIT="$COMMIT" VERSION="$VERSION" OUTPUT_DIR="$2" \
      ROUTER_BASE=/dashboard/ RESOURCE_BASE=/dashboard/ yarn run build
  ' _ "$src" "$dist"

  [ -f "$dist/index.html" ] || die "build produced no index.html in '$dist'"
  log_ok "dashboard dist ready: $dist"
  printf '%s\n' "$dist"
}
