#!/usr/bin/env bats
# Exhaustive unit tests for the SHA256 download gate in lib/download.sh.
# Pure helpers and the orchestrator are tested with local fixtures and a mocked
# fetcher: no network, no real downloads. The bar is fail-closed correctness on
# every malformed, truncated, mismatched, or empty checksum.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  . "$ROOT/lib/util.sh"
  # shellcheck source=../lib/download.sh
  . "$ROOT/lib/download.sh"

  TMP="$(mktemp -d)"
  # A real file and its real sha256, so verification is end-to-end honest.
  printf 'muster payload\n' >"$TMP/artifact"
  GOOD="$(sha256sum "$TMP/artifact" | awk '{print $1}')"
  BAD='0000000000000000000000000000000000000000000000000000000000000000'
}

teardown() {
  rm -rf "$TMP"
}

# --- dv_normalize_sha --------------------------------------------------------

@test "dv_normalize_sha accepts a clean 64-hex digest unchanged" {
  run dv_normalize_sha "$GOOD"
  [ "$status" -eq 0 ]
  [ "$output" = "$GOOD" ]
}

@test "dv_normalize_sha lowercases an uppercase digest" {
  up="$(printf '%s' "$GOOD" | tr 'a-f' 'A-F')"
  run dv_normalize_sha "$up"
  [ "$status" -eq 0 ]
  [ "$output" = "$GOOD" ]
}

@test "dv_normalize_sha trims surrounding whitespace" {
  run dv_normalize_sha "   $GOOD	"
  [ "$status" -eq 0 ]
  [ "$output" = "$GOOD" ]
}

@test "dv_normalize_sha rejects the empty string" {
  run dv_normalize_sha ""
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "dv_normalize_sha rejects an unset argument" {
  run dv_normalize_sha
  [ "$status" -ne 0 ]
}

@test "dv_normalize_sha rejects a too-short digest" {
  run dv_normalize_sha "abc123"
  [ "$status" -ne 0 ]
}

@test "dv_normalize_sha rejects a 65-char digest" {
  run dv_normalize_sha "${GOOD}a"
  [ "$status" -ne 0 ]
}

@test "dv_normalize_sha rejects non-hex characters" {
  run dv_normalize_sha "g000000000000000000000000000000000000000000000000000000000000000"
  [ "$status" -ne 0 ]
}

@test "dv_normalize_sha rejects a sha256: prefix (caller must strip it)" {
  run dv_normalize_sha "sha256:$GOOD"
  [ "$status" -ne 0 ]
}

# --- dv_check ----------------------------------------------------------------

@test "dv_check matches identical digests" {
  run dv_check "$GOOD" "$GOOD"
  [ "$status" -eq 0 ]
}

@test "dv_check matches across case differences" {
  up="$(printf '%s' "$GOOD" | tr 'a-f' 'A-F')"
  run dv_check "$GOOD" "$up"
  [ "$status" -eq 0 ]
}

@test "dv_check fails on a real mismatch" {
  run dv_check "$GOOD" "$BAD"
  [ "$status" -ne 0 ]
}

@test "dv_check fails closed when expected is empty" {
  run dv_check "$GOOD" ""
  [ "$status" -ne 0 ]
}

@test "dv_check fails closed when actual is empty" {
  run dv_check "" "$GOOD"
  [ "$status" -ne 0 ]
}

@test "dv_check fails closed when expected is malformed" {
  run dv_check "$GOOD" "not-a-checksum"
  [ "$status" -ne 0 ]
}

# --- dv_sha_from_file --------------------------------------------------------

@test "dv_sha_from_file reads field 1 of a single-line checksum file" {
  printf '%s  kubectl\n' "$GOOD" >"$TMP/c.sha256"
  run dv_sha_from_file "$TMP/c.sha256"
  [ "$status" -eq 0 ]
  [ "$output" = "$GOOD" ]
}

@test "dv_sha_from_file takes only the first line" {
  printf '%s  a\n%s  b\n' "$GOOD" "$BAD" >"$TMP/c.sha256"
  run dv_sha_from_file "$TMP/c.sha256"
  [ "$output" = "$GOOD" ]
}

@test "dv_sha_from_file fails on a missing file" {
  run dv_sha_from_file "$TMP/nope"
  [ "$status" -ne 0 ]
}

# --- dv_sha_from_list --------------------------------------------------------

@test "dv_sha_from_list matches the line for the named artifact" {
  printf '%s  cloudflared-linux-amd64\n%s  cloudflared-linux-arm64\n' \
    "$GOOD" "$BAD" >"$TMP/sums"
  run dv_sha_from_list "$TMP/sums" "cloudflared-linux-amd64"
  [ "$status" -eq 0 ]
  [ "$output" = "$GOOD" ]
}

@test "dv_sha_from_list does not match a name that is a substring of another" {
  printf '%s  cloudflared-linux-amd64-extra\n' "$BAD" >"$TMP/sums"
  run dv_sha_from_list "$TMP/sums" "cloudflared-linux-amd64"
  [ -z "$output" ]
}

@test "dv_sha_from_list yields nothing for an absent name" {
  printf '%s  other\n' "$GOOD" >"$TMP/sums"
  run dv_sha_from_list "$TMP/sums" "cloudflared-linux-amd64"
  [ -z "$output" ]
}

@test "dv_sha_from_list fails when the name argument is empty" {
  printf '%s  other\n' "$GOOD" >"$TMP/sums"
  run dv_sha_from_list "$TMP/sums" ""
  [ "$status" -ne 0 ]
}

# --- dv_sha_from_gh_json -----------------------------------------------------

@test "dv_sha_from_gh_json extracts the digest of the matching asset" {
  cat >"$TMP/rel.json" <<EOF
{"assets":[{"name":"other.yaml","digest":"sha256:$BAD"},{"name":"cert-manager.crds.yaml","digest":"sha256:$GOOD"}]}
EOF
  run dv_sha_from_gh_json "$TMP/rel.json" "cert-manager.crds.yaml"
  [ "$status" -eq 0 ]
  [ "$output" = "$GOOD" ]
}

@test "dv_sha_from_gh_json returns nothing when the asset is absent" {
  cat >"$TMP/rel.json" <<EOF
{"assets":[{"name":"other.yaml","digest":"sha256:$BAD"}]}
EOF
  run dv_sha_from_gh_json "$TMP/rel.json" "cert-manager.crds.yaml"
  [ -z "$output" ]
}

@test "dv_sha_from_gh_json picks the digest belonging to the named asset" {
  # Asset with no digest must not borrow the next asset's digest.
  cat >"$TMP/rel.json" <<EOF
{"assets":[{"name":"cert-manager.crds.yaml"},{"name":"later.yaml","digest":"sha256:$BAD"}]}
EOF
  run dv_sha_from_gh_json "$TMP/rel.json" "cert-manager.crds.yaml"
  [ "$output" != "$BAD" ]
}

# --- dv_file_sha -------------------------------------------------------------

@test "dv_file_sha computes the sha256 of a real file" {
  run dv_file_sha "$TMP/artifact"
  [ "$status" -eq 0 ]
  [ "$output" = "$GOOD" ]
}

@test "dv_file_sha fails on an unreadable path" {
  run dv_file_sha "$TMP/missing"
  [ "$status" -ne 0 ]
}

# --- download_verify orchestrator (mocked fetch) -----------------------------

# Replace the network fetcher with one that copies a local payload, so the
# orchestrator exercises real verification logic without touching the network.
_mock_fetch_ok() { cp "$TMP/artifact" "$2"; }
_mock_fetch_corrupt() { printf 'tampered\n' >"$2"; }
_mock_fetch_fail() { return 1; }

@test "download_verify installs an artifact whose inline checksum matches" {
  dv_fetch() { _mock_fetch_ok "$@"; }
  DV_URL="https://example/x" DV_DEST="$TMP/out" DV_FORMAT="inline" DV_SHA256="$GOOD" \
    run download_verify
  [ "$status" -eq 0 ]
  [ -f "$TMP/out" ]
  [ "$(sha256sum "$TMP/out" | awk '{print $1}')" = "$GOOD" ]
}

@test "download_verify aborts when the downloaded bytes do not match" {
  dv_fetch() { _mock_fetch_corrupt "$@"; }
  DV_URL="https://example/x" DV_DEST="$TMP/out" DV_FORMAT="inline" DV_SHA256="$GOOD" \
    run download_verify
  [ "$status" -ne 0 ]
  [ ! -f "$TMP/out" ]
}

@test "download_verify aborts when the inline checksum is empty (fail-closed)" {
  dv_fetch() { _mock_fetch_ok "$@"; }
  DV_URL="https://example/x" DV_DEST="$TMP/out" DV_FORMAT="inline" DV_SHA256="" \
    run download_verify
  [ "$status" -ne 0 ]
  [ ! -f "$TMP/out" ]
}

@test "download_verify aborts when the download itself fails" {
  dv_fetch() { _mock_fetch_fail "$@"; }
  DV_URL="https://example/x" DV_DEST="$TMP/out" DV_FORMAT="inline" DV_SHA256="$GOOD" \
    run download_verify
  [ "$status" -ne 0 ]
  [ ! -f "$TMP/out" ]
}

@test "download_verify reuses an already-verified destination without refetching" {
  cp "$TMP/artifact" "$TMP/out"
  dv_fetch() { _mock_fetch_fail "$@"; } # would fail if called
  DV_URL="https://example/x" DV_DEST="$TMP/out" DV_FORMAT="inline" DV_SHA256="$GOOD" \
    run download_verify
  [ "$status" -eq 0 ]
  [ -f "$TMP/out" ]
}

@test "download_verify rejects an unknown format" {
  dv_fetch() { _mock_fetch_ok "$@"; }
  DV_URL="https://example/x" DV_DEST="$TMP/out" DV_FORMAT="bogus" \
    run download_verify
  [ "$status" -ne 0 ]
}

@test "download_verify verifies via a github_sha256sum checksum list" {
  printf '%s  payload.bin\n' "$GOOD" >"$TMP/sums"
  dv_fetch() {
    case "$1" in
      *sums) cp "$TMP/sums" "$2" ;;
      *) cp "$TMP/artifact" "$2" ;;
    esac
  }
  DV_URL="https://example/payload.bin" DV_DEST="$TMP/out" \
    DV_FORMAT="github_sha256sum" DV_CHECKSUM_URL="https://example/sums" \
    DV_ARTIFACT_NAME="payload.bin" run download_verify
  [ "$status" -eq 0 ]
  [ -f "$TMP/out" ]
}
