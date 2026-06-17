#!/usr/bin/env bats
# Unit tests for the build-ui branch/version logic in lib/buildui.sh.
# Pure helpers run with no network; the git-backed helpers use a throwaway
# repo created in setup so branch existence + master fallback are exercised
# for real without touching ~/repos/dashboard.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  . "$ROOT/lib/util.sh"
  # shellcheck source=../lib/buildui.sh
  . "$ROOT/lib/buildui.sh"
}

# --- ui_branch_from_tag: the head -> master / vX.Y -> release-X.Y mapping -----

@test "ui_branch_from_tag: head maps to master" {
  [ "$(ui_branch_from_tag head)" = "master" ]
}

@test "ui_branch_from_tag: vX.Y-head maps to that release line" {
  [ "$(ui_branch_from_tag v2.14-head)" = "release-2.14" ]
}

@test "ui_branch_from_tag: bare X.Y-head maps to that release line" {
  [ "$(ui_branch_from_tag 2.14-head)" = "release-2.14" ]
}

@test "ui_branch_from_tag: an rc pin maps to its release line" {
  [ "$(ui_branch_from_tag 2.14.2-rc1)" = "release-2.14" ]
}

@test "ui_branch_from_tag: a bare patch version maps to its release line" {
  [ "$(ui_branch_from_tag 2.13.4)" = "release-2.13" ]
}

@test "ui_branch_from_tag: a leading-v minor maps to its release line" {
  [ "$(ui_branch_from_tag v2.13)" = "release-2.13" ]
}

@test "ui_branch_from_tag: a brand-new minor still maps mechanically (fallback is impure)" {
  [ "$(ui_branch_from_tag v2.15-head)" = "release-2.15" ]
}

@test "ui_branch_from_tag: a non-version tag is refused" {
  run ui_branch_from_tag latest
  [ "$status" -ne 0 ]
}

# --- engines_min_major: parse package.json engines.node ranges ---------------

@test "engines_min_major: >=24.0.0 yields 24" {
  [ "$(engines_min_major '>=24.0.0')" = "24" ]
}

@test "engines_min_major: caret range yields the base major" {
  [ "$(engines_min_major '^20.10.0')" = "20" ]
}

@test "engines_min_major: empty range yields empty" {
  [ -z "$(engines_min_major '')" ]
}

# --- node_major: reduce node --version output --------------------------------

@test "node_major: strips the leading v" {
  [ "$(node_major v24.3.1)" = "24" ]
}

@test "node_major: tolerates a bare version" {
  [ "$(node_major 20.11.0)" = "20" ]
}

# --- ui_resolve_branch: real git, master fallback for a missing branch -------

_mkrepo() {
  REPO="$(mktemp -d)"
  git -C "$REPO" init -q
  git -C "$REPO" config user.email t@t.t
  git -C "$REPO" config user.name t
  git -C "$REPO" commit -q --allow-empty -m init
  git -C "$REPO" branch -m master
  git -C "$REPO" branch release-2.14
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

@test "ui_resolve_branch: head resolves to master" {
  _mkrepo
  [ "$(ui_resolve_branch "$REPO" head)" = "master" ]
}

@test "ui_resolve_branch: an existing release branch is used" {
  _mkrepo
  [ "$(ui_resolve_branch "$REPO" v2.14-head)" = "release-2.14" ]
}

@test "ui_resolve_branch: a missing release branch falls back to master" {
  _mkrepo
  [ "$(ui_resolve_branch "$REPO" v2.15-head)" = "master" ]
}

# --- ui_engines_node: read the range out of a package.json -------------------

@test "ui_engines_node: reads the declared node range" {
  d="$(mktemp -d)"
  printf '%s\n' '{' '  "engines": {' '    "node": ">=24.0.0"' '  }' '}' >"$d/package.json"
  run ui_engines_node "$d"
  [ "$status" -eq 0 ]
  [ "$output" = ">=24.0.0" ]
  rm -rf "$d"
}

@test "ui_engines_node: a missing package.json is refused" {
  run ui_engines_node "$(mktemp -d)"
  [ "$status" -ne 0 ]
}
