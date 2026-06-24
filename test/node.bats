#!/usr/bin/env bats
# Unit tests for lib/node.sh. Only the pure helpers and the file-backed
# resolution (node_target_major over .nvmrc / engines) are exercised here;
# nothing downloads. ui_engines_node/engines_min_major come from buildui.sh,
# so both libs are sourced.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  . "$ROOT/lib/util.sh"
  # shellcheck source=../lib/buildui.sh
  . "$ROOT/lib/buildui.sh"
  # shellcheck source=../lib/node.sh
  . "$ROOT/lib/node.sh"
}

# --- node_parse_nvmrc: read the major out of an .nvmrc -----------------------

@test "node_parse_nvmrc: a bare major" {
  [ "$(node_parse_nvmrc '20')" = "20" ]
}

@test "node_parse_nvmrc: a leading-v full version" {
  [ "$(node_parse_nvmrc 'v20.10.0')" = "20" ]
}

@test "node_parse_nvmrc: a full version without v" {
  [ "$(node_parse_nvmrc '24.3.1')" = "24" ]
}

@test "node_parse_nvmrc: trims surrounding whitespace and a trailing newline" {
  [ "$(node_parse_nvmrc '  22
')" = "22" ]
}

@test "node_parse_nvmrc: a non-numeric pin yields nothing" {
  [ -z "$(node_parse_nvmrc 'lts/iron')" ]
}

@test "node_parse_nvmrc: empty input yields nothing" {
  [ -z "$(node_parse_nvmrc '')" ]
}

# --- node_platform_tag: uname -> nodejs.org artifact platform ----------------

@test "node_platform_tag: macOS arm64" {
  [ "$(node_platform_tag Darwin arm64)" = "darwin-arm64" ]
}

@test "node_platform_tag: linux x86_64" {
  [ "$(node_platform_tag Linux x86_64)" = "linux-x64" ]
}

@test "node_platform_tag: linux aarch64" {
  [ "$(node_platform_tag Linux aarch64)" = "linux-arm64" ]
}

@test "node_platform_tag: an unknown OS is refused" {
  run node_platform_tag Plan9 x86_64
  [ "$status" -ne 0 ]
}

@test "node_platform_tag: an unknown arch is refused" {
  run node_platform_tag Linux mips
  [ "$status" -ne 0 ]
}

# --- node_pick_latest: newest version for a major out of index.tab -----------

_index() {
  printf '%s\n' \
    'version	date	files' \
    'v24.3.0	2025-01-02	x' \
    'v22.14.0	2025-01-01	x' \
    'v22.13.1	2024-12-31	x' \
    'v20.18.1	2024-12-30	x'
}

@test "node_pick_latest: picks the newest patch for the major" {
  [ "$(_index | node_pick_latest 22)" = "v22.14.0" ]
}

@test "node_pick_latest: honours the header row and major boundary" {
  [ "$(_index | node_pick_latest 24)" = "v24.3.0" ]
  [ "$(_index | node_pick_latest 20)" = "v20.18.1" ]
}

@test "node_pick_latest: a major with no release yields nothing" {
  [ -z "$(_index | node_pick_latest 18)" ]
}

@test "node_pick_latest: a short major does not match a longer one" {
  # major 2 must not match v20/v22/v24 lines
  [ -z "$(_index | node_pick_latest 2)" ]
}

# --- node_target_major: .nvmrc first, then the engines floor -----------------

@test "node_target_major: prefers .nvmrc when present" {
  d="$(mktemp -d)"
  printf '20\n' >"$d/.nvmrc"
  printf '%s\n' '{ "engines": { "node": ">=24.0.0" } }' >"$d/package.json"
  [ "$(node_target_major "$d")" = "20" ]
  rm -rf "$d"
}

@test "node_target_major: falls back to the engines floor without .nvmrc" {
  d="$(mktemp -d)"
  printf '%s\n' '{ "engines": { "node": ">=24.0.0" } }' >"$d/package.json"
  [ "$(node_target_major "$d")" = "24" ]
  rm -rf "$d"
}

@test "node_target_major: falls back when .nvmrc is non-numeric" {
  d="$(mktemp -d)"
  printf 'lts/iron\n' >"$d/.nvmrc"
  printf '%s\n' '{ "engines": { "node": ">=20.0.0" } }' >"$d/package.json"
  [ "$(node_target_major "$d")" = "20" ]
  rm -rf "$d"
}

# --- ui_resolve_node: the NODE_BIN escape hatch ------------------------------

@test "ui_resolve_node: NODE_BIN directory is used verbatim" {
  d="$(mktemp -d)"
  mkdir -p "$d/bin"
  : >"$d/bin/node"
  chmod +x "$d/bin/node"
  NODE_BIN="$d/bin" run ui_resolve_node "$d"
  [ "$status" -eq 0 ]
  [ "$output" = "$d/bin" ]
  rm -rf "$d"
}

@test "ui_resolve_node: NODE_BIN pointing at a node binary yields its dir" {
  d="$(mktemp -d)"
  mkdir -p "$d/bin"
  : >"$d/bin/node"
  chmod +x "$d/bin/node"
  NODE_BIN="$d/bin/node" run ui_resolve_node "$d"
  [ "$status" -eq 0 ]
  [ "$output" = "$d/bin" ]
  rm -rf "$d"
}

@test "ui_resolve_node: an invalid NODE_BIN is refused" {
  d="$(mktemp -d)"
  NODE_BIN="$d/nope" run ui_resolve_node "$d"
  [ "$status" -ne 0 ]
  rm -rf "$d"
}
