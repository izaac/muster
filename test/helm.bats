#!/usr/bin/env bats
# Exhaustive unit tests for the Rancher version matrix in lib/helm.sh.
# Pure helpers only: no helm, no network. Fixtures mimic the real layout of
# `helm search repo <repo> --devel --versions` (tab-separated, header row).

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  . "$ROOT/lib/util.sh"
  # shellcheck source=../lib/helm.sh
  . "$ROOT/lib/helm.sh"

  # Optimus latest (Prime RC staging): newest first, mixed minors + an RC ladder.
  SEARCH_LATEST="$(
    printf '%s\n' \
      'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
      'rancher-latest/rancher	2.13.0-rc2	2.13.0-rc2	Install Rancher Server' \
      'rancher-latest/rancher	2.13.0-rc1	2.13.0-rc1	Install Rancher Server' \
      'rancher-latest/rancher	2.12.5-rc3	2.12.5-rc3	Install Rancher Server' \
      'rancher-latest/rancher	2.12.5-rc2	2.12.5-rc2	Install Rancher Server' \
      'rancher-latest/rancher	2.12.5-rc10	2.12.5-rc10	Install Rancher Server' \
      'rancher-latest/rancher	2.12.4	2.12.4	Install Rancher Server'
  )"

  # Optimus alpha: alpha ladder across two minors. Rows are in helm's own
  # (lexical) order, where alpha9 ranks above alpha10/alpha14, so a naive
  # head -1 would pick the stale alpha9 instead of the real newest alpha14.
  SEARCH_ALPHA="$(
    printf '%s\n' \
      'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
      'rancher-alpha/rancher	2.14.0-alpha9	2.14.0-alpha9	Install Rancher Server' \
      'rancher-alpha/rancher	2.14.0-alpha8	2.14.0-alpha8	Install Rancher Server' \
      'rancher-alpha/rancher	2.14.0-alpha14	2.14.0-alpha14	Install Rancher Server' \
      'rancher-alpha/rancher	2.14.0-alpha10	2.14.0-alpha10	Install Rancher Server' \
      'rancher-alpha/rancher	2.13.0-alpha2	2.13.0-alpha2	Install Rancher Server'
  )"

  # Prime stable: plain GA versions, no pre-release suffixes (no filter branch).
  SEARCH_PRIME="$(
    printf '%s\n' \
      'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
      'rancher-prime/rancher	2.10.2	2.10.2	Install Rancher Server' \
      'rancher-prime/rancher	2.10.1	2.10.1	Install Rancher Server' \
      'rancher-prime/rancher	2.9.5	2.9.5	Install Rancher Server'
  )"

  # Prime stable with a GA and its own hotfix sibling for the same base, plus a
  # later GA patch. A plain 2.13.3 pin must return the GA, not the -hotfix row,
  # even though a bare sort -V would rank the suffixed string differently.
  SEARCH_PRIME_HOTFIX="$(
    printf '%s\n' \
      'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
      'rancher-prime/rancher	2.13.6	2.13.6	Install Rancher Server' \
      'rancher-prime/rancher	2.13.3-hotfix-751b.1	2.13.3-hotfix-751b.1	Install Rancher Server' \
      'rancher-prime/rancher	2.13.3	2.13.3	Install Rancher Server'
  )"

  # Chart index.yaml fragments (the freshness path parses these for dates).
  INDEX_ALPHA="$(
    printf '%s\n' \
      '  rancher:' \
      '  - apiVersion: v2' \
      '    version: 2.14.3-alpha6' \
      '    created: 2026-06-26T10:00:00Z' \
      '  - apiVersion: v2' \
      '    version: 2.14.3-alpha5' \
      '    created: 2026-06-20T10:00:00Z' \
      '  - apiVersion: v2' \
      '    version: 2.16.0-alpha1' \
      '    created: 2026-06-28T10:00:00Z'
  )"
  INDEX_LATEST="$(
    printf '%s\n' \
      '  rancher:' \
      '  - apiVersion: v2' \
      '    version: 2.14.2-rc1' \
      '    created: 2026-05-27T10:00:00Z'
  )"
}

# --- version_string ----------------------------------------------------------

@test "version_string strips pre-release suffix" {
  [ "$(version_string 2.10.1-rc3)" = "2.10.1" ]
  [ "$(version_string 2.9.0-alpha13)" = "2.9.0" ]
}

@test "version_string strips a leading v" {
  [ "$(version_string v2.14)" = "2.14" ]
  [ "$(version_string v2.13.4-rc1)" = "2.13.4" ]
}

@test "version_string leaves head and bare versions intact" {
  [ "$(version_string head)" = "head" ]
  [ "$(version_string 2.11.0)" = "2.11.0" ]
}

# --- repo map ----------------------------------------------------------------

@test "repo_valid accepts the six known channels" {
  for k in rancher-prime rancher-latest rancher-alpha \
    rancher-community rancher-com-rc rancher-com-alpha; do
    run repo_valid "$k"
    [ "$status" -eq 0 ] || {
      echo "expected valid: $k"
      false
    }
  done
}

@test "repo_valid rejects unknown or empty channels" {
  run repo_valid rancher-bogus
  [ "$status" -ne 0 ]
  run repo_valid ""
  [ "$status" -ne 0 ]
  run repo_valid
  [ "$status" -ne 0 ]
}

@test "repo_url and repo_image map prime to the gated registry" {
  [ "$(repo_url rancher-prime)" = "https://charts.rancher.com/server-charts/prime" ]
  [ "$(repo_image rancher-prime)" = "registry.suse.com/rancher/rancher" ]
}

@test "staging channels use the optimus charts and stgregistry image" {
  [ "$(repo_url rancher-latest)" = "https://charts.optimus.rancher.io/server-charts/latest" ]
  [ "$(repo_url rancher-alpha)" = "https://charts.optimus.rancher.io/server-charts/alpha" ]
  [ "$(repo_image rancher-latest)" = "stgregistry.suse.com/rancher/rancher" ]
  [ "$(repo_image rancher-alpha)" = "stgregistry.suse.com/rancher/rancher" ]
}

@test "community channels have an empty image (Docker Hub, tag as-is)" {
  [ "$(repo_image rancher-community)" = "" ]
  [ "$(repo_image rancher-com-rc)" = "" ]
  [ "$(repo_image rancher-com-alpha)" = "" ]
}

# --- resolve_chart_version: head ---------------------------------------------

@test "head selects the newest by version sort, not helm's lexical order" {
  [ "$(resolve_chart_version rancher-latest head "$SEARCH_LATEST")" = "2.13.0-rc2" ]
  [ "$(resolve_chart_version rancher-alpha head "$SEARCH_ALPHA")" = "2.14.0-alpha14" ]
}

# --- resolve_chart_version: rancher-latest (-rc filter) ----------------------

@test "latest with a minor pin selects the highest -rc for that minor" {
  [ "$(resolve_chart_version rancher-latest 2.13 "$SEARCH_LATEST")" = "2.13.0-rc2" ]
}

@test "latest -rc sort is numeric, not lexical (rc10 > rc3)" {
  [ "$(resolve_chart_version rancher-latest 2.12.5 "$SEARCH_LATEST")" = "2.12.5-rc10" ]
}

@test "latest accepts a v-prefixed tag" {
  [ "$(resolve_chart_version rancher-latest v2.13 "$SEARCH_LATEST")" = "2.13.0-rc2" ]
}

@test "latest ignores GA rows that lack an -rc suffix" {
  # 2.12.4 is GA (no -rc); a 2.12.4 pin therefore resolves nothing on latest.
  run resolve_chart_version rancher-latest 2.12.4 "$SEARCH_LATEST"
  [ -z "$output" ]
}

# --- resolve_chart_version: rancher-alpha (-alpha filter) --------------------

@test "alpha with a minor pin selects the highest -alpha for that minor" {
  [ "$(resolve_chart_version rancher-alpha 2.14 "$SEARCH_ALPHA")" = "2.14.0-alpha14" ]
  [ "$(resolve_chart_version rancher-alpha 2.13 "$SEARCH_ALPHA")" = "2.13.0-alpha2" ]
}

@test "alpha minor pin sort is numeric, not lexical (alpha14 > alpha9)" {
  [ "$(resolve_chart_version rancher-alpha 2.14 "$SEARCH_ALPHA")" = "2.14.0-alpha14" ]
}

# --- resolve_chart_version: no-filter channels -------------------------------

@test "prime with an exact pin resolves that version" {
  [ "$(resolve_chart_version rancher-prime 2.10.1 "$SEARCH_PRIME")" = "2.10.1" ]
}

@test "prime with a minor pin takes the highest patch" {
  [ "$(resolve_chart_version rancher-prime 2.10 "$SEARCH_PRIME")" = "2.10.2" ]
}

@test "an unmatched pin resolves to empty" {
  run resolve_chart_version rancher-prime 9.9.9 "$SEARCH_PRIME"
  [ -z "$output" ]
}

@test "an empty search resolves to empty for head and pins alike" {
  run resolve_chart_version rancher-latest head ""
  [ -z "$output" ]
  run resolve_chart_version rancher-prime 2.10.1 ""
  [ -z "$output" ]
}

# --- resolve_image_tag -------------------------------------------------------

@test "image tag is v<chart_version> when the channel pins an image" {
  [ "$(resolve_image_tag stgregistry.suse.com/rancher/rancher 2.13.0-rc2 v2.13)" = "v2.13.0-rc2" ]
  [ "$(resolve_image_tag registry.suse.com/rancher/rancher 2.10.1 2.10.1)" = "v2.10.1" ]
}

@test "image tag is the literal tag when the channel has no image" {
  [ "$(resolve_image_tag '' 2.14.0 head)" = "head" ]
  [ "$(resolve_image_tag '' 2.13.3 v2.13.3)" = "v2.13.3" ]
}

# --- cert-manager CRD pin ----------------------------------------------------

@test "the pinned cert-manager CRD checksum is a well-formed sha256" {
  # Guards against a typo in the source pin: it must be exactly 64 hex chars.
  . "$ROOT/lib/download.sh"
  pin="${MUSTER_CERT_MANAGER_CRDS_SHA256[$CERT_MANAGER_VERSION_DEFAULT]}"
  run dv_normalize_sha "$pin"
  [ "$status" -eq 0 ]
  [ "$output" = "$pin" ]
}

# --- resolve_chart_version: GA outranks its own hotfix/pre-release -----------

@test "a plain GA pin beats a same-base hotfix sibling (prime)" {
  [ "$(resolve_chart_version rancher-prime 2.13.3 "$SEARCH_PRIME_HOTFIX")" = "2.13.3" ]
}

@test "a prime-only late GA patch pins exactly (2.13.6)" {
  [ "$(resolve_chart_version rancher-prime 2.13.6 "$SEARCH_PRIME_HOTFIX")" = "2.13.6" ]
}

@test "a prime minor pin takes the highest GA, not a hotfix" {
  [ "$(resolve_chart_version rancher-prime 2.13 "$SEARCH_PRIME_HOTFIX")" = "2.13.6" ]
}

# --- freshness pure helpers --------------------------------------------------

@test "index_rancher_dates emits stab|version|created per rancher entry" {
  out="$(printf '%s\n' "$INDEX_LATEST" | index_rancher_dates)"
  [ "$out" = "0|2.14.2-rc1|2026-05-27T10:00:00Z" ]
}

@test "newest_dated filters by prerelease and returns the newest version|date" {
  out="$(printf '%s\n' "$INDEX_ALPHA" | index_rancher_dates \
    | newest_dated '' '-alpha')"
  [ "$out" = "2.16.0-alpha1|2026-06-28" ]
}

@test "newest_dated honours a minor version regex" {
  out="$(printf '%s\n' "$INDEX_ALPHA" | index_rancher_dates \
    | newest_dated '2[.]14([.]|-)' '-alpha')"
  [ "$out" = "2.14.3-alpha6|2026-06-26" ]
}

@test "parse_dockerhub_date pulls the date out of last_updated" {
  [ "$(parse_dockerhub_date '{"name":"head","last_updated":"2026-06-29T12:00:00.123Z"}')" = "2026-06-29" ]
  [ -z "$(parse_dockerhub_date '{}')" ]
}

# --- freshness_maybe_promote: precedence and date logic ----------------------
# These stub the two impure fetchers so the decision logic is exercised with no
# network. The stubs shadow the real functions after lib/helm.sh is sourced.

@test "promotes head to the newest staging channel when staging is newer" {
  fetch_dockerhub_date() { echo "2026-06-20"; }
  fetch_index_dates() {
    case "$1" in
      rancher-latest) printf '%s\n' '0|2.14.2-rc1|2026-05-27T00:00:00Z' ;;
      rancher-alpha) printf '%s\n' '0|2.14.3-alpha6|2026-06-26T00:00:00Z' ;;
    esac
  }
  PREFER_STAGING=1 RANCHER_REPO=rancher-com-alpha RANCHER_IMAGE_TAG=head
  freshness_maybe_promote
  [ "$RANCHER_REPO" = "rancher-alpha" ]
  [ "$RANCHER_IMAGE_TAG" = "v2.14.3-alpha6" ]
}

@test "keeps community when head is still the newest" {
  fetch_dockerhub_date() { echo "2026-06-29"; }
  fetch_index_dates() {
    case "$1" in
      rancher-latest) printf '%s\n' '0|2.14.2-rc1|2026-05-27T00:00:00Z' ;;
      rancher-alpha) printf '%s\n' '0|2.14.3-alpha6|2026-06-26T00:00:00Z' ;;
    esac
  }
  PREFER_STAGING=1 RANCHER_REPO=rancher-com-alpha RANCHER_IMAGE_TAG=head
  freshness_maybe_promote
  [ "$RANCHER_REPO" = "rancher-com-alpha" ]
  [ "$RANCHER_IMAGE_TAG" = "head" ]
}

@test "an explicit concrete version pin is never promoted (override wins)" {
  fetch_dockerhub_date() { echo "2000-01-01"; }
  fetch_index_dates() { printf '%s\n' '0|9.9.9-alpha1|2099-01-01T00:00:00Z'; }
  PREFER_STAGING=1 RANCHER_REPO=rancher-com-alpha RANCHER_IMAGE_TAG=2.14.2
  freshness_maybe_promote
  [ "$RANCHER_REPO" = "rancher-com-alpha" ]
  [ "$RANCHER_IMAGE_TAG" = "2.14.2" ]
}

@test "the flag off leaves the backend untouched" {
  fetch_dockerhub_date() { echo "2000-01-01"; }
  fetch_index_dates() { printf '%s\n' '0|9.9.9-alpha1|2099-01-01T00:00:00Z'; }
  PREFER_STAGING=false RANCHER_REPO=rancher-com-alpha RANCHER_IMAGE_TAG=head
  freshness_maybe_promote
  [ "$RANCHER_REPO" = "rancher-com-alpha" ]
  [ "$RANCHER_IMAGE_TAG" = "head" ]
}

@test "a vX.Y-head tag restricts the staging race to that minor" {
  fetch_dockerhub_date() { echo "2026-06-20"; }
  fetch_index_dates() {
    case "$1" in
      rancher-latest) printf '%s\n' '0|2.14.2-rc1|2026-05-27T00:00:00Z' ;;
      rancher-alpha) printf '%s\n' \
        '0|2.16.0-alpha1|2026-06-28T00:00:00Z' \
        '0|2.14.3-alpha6|2026-06-26T00:00:00Z' ;;
    esac
  }
  PREFER_STAGING=1 RANCHER_REPO=rancher-com-rc RANCHER_IMAGE_TAG=v2.14-head
  freshness_maybe_promote
  [ "$RANCHER_REPO" = "rancher-alpha" ]
  [ "$RANCHER_IMAGE_TAG" = "v2.14.3-alpha6" ]
}
@test "a same-day staging build is a tie and keeps community" {
  fetch_dockerhub_date() { echo "2026-06-26"; }
  fetch_index_dates() {
    case "$1" in
      rancher-latest) printf '%s\n' '0|2.14.2-rc1|2026-05-27T00:00:00Z' ;;
      rancher-alpha) printf '%s\n' '0|2.14.3-alpha6|2026-06-26T09:30:00Z' ;;
    esac
  }
  PREFER_STAGING=1 RANCHER_REPO=rancher-com-alpha RANCHER_IMAGE_TAG=head
  freshness_maybe_promote
  [ "$RANCHER_REPO" = "rancher-com-alpha" ]
  [ "$RANCHER_IMAGE_TAG" = "head" ]
}

@test "promotion announces PROMOTE in the log" {
  fetch_dockerhub_date() { echo "2026-06-20"; }
  fetch_index_dates() {
    case "$1" in
      rancher-latest) printf '%s\n' '0|2.14.2-rc1|2026-05-27T00:00:00Z' ;;
      rancher-alpha) printf '%s\n' '0|2.14.3-alpha6|2026-06-26T00:00:00Z' ;;
    esac
  }
  PREFER_STAGING=1 RANCHER_REPO=rancher-com-alpha RANCHER_IMAGE_TAG=head
  run freshness_maybe_promote
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROMOTE community -> rancher-alpha"* ]]
  [[ "$output" == *"2.14.3-alpha6"* ]]
}
