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

  # The fixtures below carry frozen dates and the Prime staleness gate reads the
  # real clock, so pin "now" too: these tests must not start failing in November.
  MUSTER_TODAY=2026-09-05

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

@test "repo_valid accepts the seven known channels" {
  for k in rancher-prime rancher-prime-ga rancher-latest rancher-alpha \
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

@test "repo_url and repo_image map GA prime to the ungated registry" {
  [ "$(repo_url rancher-prime-ga)" = "https://charts.rancher.com/server-charts/prime" ]
  [ "$(repo_image rancher-prime-ga)" = "registry.rancher.com/rancher/rancher" ]
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

@test "index_rancher_dates emits rank|version|created per rancher entry" {
  out="$(printf '%s\n' "$INDEX_LATEST" | index_rancher_dates)"
  [ "$out" = "2|2.14.2-rc1|2026-05-27T10:00:00Z" ]
}

@test "index_rancher_entries also captures the chart appVersion" {
  out="$(printf '%s\n' \
    '  rancher:' \
    '  - apiVersion: v2' \
    '    appVersion: v2.15.2' \
    '    created: "2026-09-23T19:29:26.240534724Z"' \
    '    version: 2.15.2' \
    '  - apiVersion: v2' \
    '    appVersion: ""' \
    '    created: "2026-08-01T00:00:00Z"' \
    '    version: 2.15.1' \
    | index_rancher_entries)"
  [ "$(printf '%s\n' "$out" | sed -n 1p)" = "3|2.15.2|2026-09-23T19:29:26.240534724Z|v2.15.2" ]
  [ "$(printf '%s\n' "$out" | sed -n 2p)" = "3|2.15.1|2026-08-01T00:00:00Z|" ]
}

@test "index_rancher_entries ranks an rc below a final release and an alpha below an rc" {
  out="$(printf '%s\n' \
    '  rancher:' \
    '  - apiVersion: v2' \
    '    version: 2.14.0' \
    '  - apiVersion: v2' \
    '    version: 2.14.0-rc2' \
    '  - apiVersion: v2' \
    '    version: 2.14.0-alpha5' \
    | index_rancher_entries | cut -d"|" -f1 | tr '\n' ' ')"
  [ "$out" = "3 2 1 " ]
}

@test "newest_release_version returns the highest release for a line" {
  out="$(printf '%s\n' "$INDEX_ALPHA" | index_rancher_dates \
    | newest_release_version '2[.]14([.]|-)')"
  [ "$out" = "2.14.3-alpha6|2026-06-26" ]
}

@test "newest_release_version excludes -head dev charts and ranks rc above alpha" {
  out="$(printf '%s\n' \
    '  rancher:' \
    '  - apiVersion: v2' \
    '    version: 2.14.5-abcdef-head' \
    '    created: 2026-08-11T10:00:00Z' \
    '  - apiVersion: v2' \
    '    version: 2.14.4-rc1' \
    '    created: 2026-07-30T10:00:00Z' \
    '  - apiVersion: v2' \
    '    version: 2.14.4-alpha7' \
    '    created: 2026-07-29T10:00:00Z' \
    | index_rancher_dates | newest_release_version '2[.]14([.]|-)')"
  [ "$out" = "2.14.4-rc1|2026-07-30" ]
}

@test "version_ahead orders patches, and rc above alpha, and GA above its rc" {
  version_ahead 2.14.4 2.14.3
  version_ahead 2.14.4-rc1 2.14.4-alpha7
  version_ahead 2.14.4 2.14.4-rc1
  version_ahead 2.14.4-rc1 2.14.3
  run version_ahead 2.15.0-rc5 2.15.0-rc5
  [ "$status" -ne 0 ]
  version_ahead 2.14.4-rc1 ""
}

@test "date_within_days measures recency and treats the future as within" {
  date_within_days 2026-07-30 2026-08-12 60
  run date_within_days 2026-05-01 2026-08-12 60
  [ "$status" -ne 0 ]
  date_within_days 2099-01-01 2026-08-12 60
}

@test "freshness_prefer_prime prefers prime unless community is strictly ahead" {
  freshness_prefer_prime 2.14.4-rc1 2.14.3 2026-07-30 2026-08-12 60
  freshness_prefer_prime 2.15.1-alpha1 2.15.1-alpha1 2026-08-05 2026-08-12 60
  run freshness_prefer_prime 2.14.4-rc1 2.14.3 2026-05-01 2026-08-12 60
  [ "$status" -ne 0 ]
  run freshness_prefer_prime 2.14.4-rc1 2.14.4 2026-08-11 2026-08-12 60
  [ "$status" -ne 0 ]
  freshness_prefer_prime 2.14.4-rc1 "" 2026-08-01 2026-08-12 60
}

# --- freshness_maybe_promote: the G4 cutoff (patch-ahead, not head date) ------
# These stub fetch_index_dates per channel so the decision runs with no network.
# MUSTER_TODAY pins "now" so the recency gate is deterministic.

@test "promotes to prime when the prime release is ahead of the community line and recent" {
  fetch_index_dates() {
    case "$1" in
      rancher-com-rc | rancher-com-alpha) printf '%s\n' '1|2.14.3|2026-06-29T00:00:00Z' ;;
      rancher-latest) printf '%s\n' '0|2.14.4-rc1|2026-07-30T00:00:00Z' ;;
      rancher-alpha) printf '%s\n' '0|2.14.4-alpha7|2026-07-29T00:00:00Z' ;;
    esac
  }
  MUSTER_TODAY=2026-08-12
  PREFER_STAGING=1 RANCHER_REPO=rancher-com-rc RANCHER_IMAGE_TAG=v2.14-head
  freshness_maybe_promote
  [ "$RANCHER_REPO" = "rancher-latest" ]
  [ "$RANCHER_IMAGE_TAG" = "v2.14.4-rc1" ]
}

@test "promotes on a tie because the prime build is the superset" {
  fetch_index_dates() {
    case "$1" in
      rancher-com-rc | rancher-com-alpha) printf '%s\n' '0|2.15.1-alpha1|2026-08-05T00:00:00Z' ;;
      rancher-latest) printf '%s\n' '0|2.15.1-alpha1|2026-08-05T00:00:00Z' ;;
      rancher-alpha) printf '%s\n' '' ;;
    esac
  }
  MUSTER_TODAY=2026-08-12
  PREFER_STAGING=1 RANCHER_REPO=rancher-com-rc RANCHER_IMAGE_TAG=v2.15-head
  freshness_maybe_promote
  [ "$RANCHER_REPO" = "rancher-latest" ]
  [ "$RANCHER_IMAGE_TAG" = "v2.15.1-alpha1" ]
}

@test "keeps community when the community line has GA'd past staging" {
  fetch_index_dates() {
    case "$1" in
      rancher-com-rc | rancher-com-alpha) printf '%s\n' '1|2.14.4|2026-08-10T00:00:00Z' ;;
      rancher-latest) printf '%s\n' '0|2.14.4-rc1|2026-07-30T00:00:00Z' ;;
      rancher-alpha) printf '%s\n' '' ;;
    esac
  }
  MUSTER_TODAY=2026-08-12
  PREFER_STAGING=1 RANCHER_REPO=rancher-com-rc RANCHER_IMAGE_TAG=v2.14-head
  freshness_maybe_promote
  [ "$RANCHER_REPO" = "rancher-com-rc" ]
  [ "$RANCHER_IMAGE_TAG" = "v2.14-head" ]
}

@test "keeps community when the prime line is ahead but stale (older than 60 days)" {
  fetch_index_dates() {
    case "$1" in
      rancher-com-rc | rancher-com-alpha) printf '%s\n' '1|2.13.3|2026-04-01T00:00:00Z' ;;
      rancher-latest) printf '%s\n' '0|2.13.8-rc1|2026-05-01T00:00:00Z' ;;
      rancher-alpha) printf '%s\n' '' ;;
    esac
  }
  MUSTER_TODAY=2026-08-12
  PREFER_STAGING=1 RANCHER_REPO=rancher-com-rc RANCHER_IMAGE_TAG=v2.13-head
  freshness_maybe_promote
  [ "$RANCHER_REPO" = "rancher-com-rc" ]
  [ "$RANCHER_IMAGE_TAG" = "v2.13-head" ]
}

@test "the newest prime chart ignores a -head dev chart in the index" {
  fetch_index_dates() {
    case "$1" in
      rancher-com-rc | rancher-com-alpha) printf '%s\n' '1|2.14.3|2026-06-29T00:00:00Z' ;;
      rancher-latest) printf '%s\n' \
        '0|2.14.5-abc-head|2026-08-11T00:00:00Z' \
        '0|2.14.4-rc1|2026-07-30T00:00:00Z' ;;
      rancher-alpha) printf '%s\n' '' ;;
    esac
  }
  MUSTER_TODAY=2026-08-12
  PREFER_STAGING=1 RANCHER_REPO=rancher-com-rc RANCHER_IMAGE_TAG=v2.14-head
  freshness_maybe_promote
  [ "$RANCHER_IMAGE_TAG" = "v2.14.4-rc1" ]
}

@test "keeps community when the line has no prime release at all" {
  fetch_index_dates() {
    case "$1" in
      rancher-com-rc | rancher-com-alpha) printf '%s\n' '0|2.15.0-rc5|2026-08-10T00:00:00Z' ;;
      *) printf '%s\n' '' ;;
    esac
  }
  MUSTER_TODAY=2026-08-12
  PREFER_STAGING=1 RANCHER_REPO=rancher-com-rc RANCHER_IMAGE_TAG=v2.15-head
  freshness_maybe_promote
  [ "$RANCHER_REPO" = "rancher-com-rc" ]
  [ "$RANCHER_IMAGE_TAG" = "v2.15-head" ]
}

@test "master head has no release line to weigh and is left alone" {
  fetch_index_dates() { printf '%s\n' '0|9.9.9-rc1|2099-01-01T00:00:00Z'; }
  MUSTER_TODAY=2026-08-12
  PREFER_STAGING=1 RANCHER_REPO=rancher-com-alpha RANCHER_IMAGE_TAG=head
  freshness_maybe_promote
  [ "$RANCHER_REPO" = "rancher-com-alpha" ]
  [ "$RANCHER_IMAGE_TAG" = "head" ]
}

@test "a concrete version pin is never promoted" {
  fetch_index_dates() { printf '%s\n' '0|9.9.9-rc1|2099-01-01T00:00:00Z'; }
  PREFER_STAGING=1 RANCHER_REPO=rancher-com-alpha RANCHER_IMAGE_TAG=2.14.2
  freshness_maybe_promote
  [ "$RANCHER_REPO" = "rancher-com-alpha" ]
  [ "$RANCHER_IMAGE_TAG" = "2.14.2" ]
}

@test "the flag off leaves the backend untouched" {
  fetch_index_dates() { printf '%s\n' '0|9.9.9-rc1|2099-01-01T00:00:00Z'; }
  PREFER_STAGING=false RANCHER_REPO=rancher-com-alpha RANCHER_IMAGE_TAG=v2.14-head
  freshness_maybe_promote
  [ "$RANCHER_REPO" = "rancher-com-alpha" ]
  [ "$RANCHER_IMAGE_TAG" = "v2.14-head" ]
}

@test "promotion announces PROMOTE in the log" {
  fetch_index_dates() {
    case "$1" in
      rancher-com-rc | rancher-com-alpha) printf '%s\n' '1|2.14.3|2026-06-29T00:00:00Z' ;;
      rancher-latest) printf '%s\n' '0|2.14.4-rc1|2026-07-30T00:00:00Z' ;;
      rancher-alpha) printf '%s\n' '' ;;
    esac
  }
  MUSTER_TODAY=2026-08-12
  PREFER_STAGING=1 RANCHER_REPO=rancher-com-rc RANCHER_IMAGE_TAG=v2.14-head
  run freshness_maybe_promote
  [ "$status" -eq 0 ]
  [[ "$output" == *"PROMOTE community -> rancher-latest"* ]]
  [[ "$output" == *"2.14.4-rc1"* ]]
}

# --- image_tag_normalize -----------------------------------------------------

@test "image_tag_normalize adds the leading v to a bare version" {
  [ "$(image_tag_normalize 2.15.0)" = "v2.15.0" ]
  [ "$(image_tag_normalize 2.15)" = "v2.15" ]
  [ "$(image_tag_normalize 2.15.0-rc5)" = "v2.15.0-rc5" ]
  [ "$(image_tag_normalize 2.15-head)" = "v2.15-head" ]
}

@test "image_tag_normalize leaves an already-prefixed version alone" {
  [ "$(image_tag_normalize v2.15.0)" = "v2.15.0" ]
  [ "$(image_tag_normalize v2.15-head)" = "v2.15-head" ]
}

@test "image_tag_normalize leaves a name that is not a version alone" {
  [ "$(image_tag_normalize head)" = "head" ]
  [ "$(image_tag_normalize latest)" = "latest" ]
}

@test "resolve_image_tag normalizes both branches" {
  # community channel: the requested tag, with the v it was missing
  [ "$(resolve_image_tag '' 2.15.0 2.15.0)" = "v2.15.0" ]
  # pinned-image channel: the chart version
  [ "$(resolve_image_tag stgregistry.suse.com/rancher/rancher 2.15.1-alpha1 2.15.1-alpha1)" = "v2.15.1-alpha1" ]
}

@test "resolve_image_tag is idempotent for an already-correct tag" {
  [ "$(resolve_image_tag '' 2.15.0 v2.15.0)" = "v2.15.0" ]
  [ "$(resolve_image_tag '' 2.15.0 head)" = "head" ]
}

# --- image preflight ---------------------------------------------------------

@test "image_registry_host treats a bare name as Docker Hub" {
  [ "$(image_registry_host rancher)" = "docker.io" ]
  [ "$(image_registry_host rancher/rancher)" = "docker.io" ]
}

@test "image_registry_host recognises a real registry host" {
  [ "$(image_registry_host stgregistry.suse.com/rancher/rancher)" = "stgregistry.suse.com" ]
  [ "$(image_registry_host registry.suse.com/rancher/rancher)" = "registry.suse.com" ]
  [ "$(image_registry_host localhost/rancher)" = "localhost" ]
  [ "$(image_registry_host my.reg:5000/rancher/rancher)" = "my.reg:5000" ]
}

@test "image_repo_path strips the registry host" {
  [ "$(image_repo_path stgregistry.suse.com/rancher/rancher)" = "rancher/rancher" ]
  [ "$(image_repo_path my.reg:5000/a/b/c)" = "a/b/c" ]
}

@test "image_repo_path implies library for a single-segment Docker Hub name" {
  [ "$(image_repo_path nginx)" = "library/nginx" ]
  [ "$(image_repo_path rancher/rancher)" = "rancher/rancher" ]
}

@test "helm_verify_image passes when the tag exists" {
  image_exists() { return 0; }
  RANCHER_IMAGE="" RANCHER_IMAGE_TAG_RESOLVED="v2.15-head"
  run helm_verify_image
  [ "$status" -eq 0 ]
  [[ "$output" == *"rancher/rancher:v2.15-head is pullable"* ]]
}

@test "helm_verify_image fails fast when the registry says the tag is missing" {
  image_exists() { return 1; }
  image_tag_suggestions() { printf '%s\n' "v2.15-head" "v2.15.0"; }
  RANCHER_IMAGE="" RANCHER_IMAGE_TAG_RESOLVED="v2.15"
  RANCHER_REPO="rancher-com-rc" RANCHER_IMAGE_TAG="v2.15"
  run helm_verify_image
  [ "$status" -ne 0 ]
  [[ "$output" == *"rancher/rancher:v2.15 does not exist"* ]]
  [[ "$output" == *"v2.15-head"* ]]
  [[ "$output" == *"v2.15.0"* ]]
}

@test "helm_verify_image only warns when the answer is inconclusive" {
  image_exists() { return 2; }
  RANCHER_IMAGE="registry.suse.com/rancher/rancher" RANCHER_IMAGE_TAG_RESOLVED="v2.15.0"
  run helm_verify_image
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not verify"* ]]
}

@test "helm_verify_image can be bypassed" {
  image_exists() { return 1; }
  MUSTER_SKIP_IMAGE_CHECK=1 RANCHER_IMAGE="" RANCHER_IMAGE_TAG_RESOLVED="nope"
  run helm_verify_image
  [ "$status" -eq 0 ]
}

# --- agentTLSMode ------------------------------------------------------------
# Rancher must never serve in strict mode behind a tunnel whose certificate it
# did not issue, so the chart value is set at install rather than patched after.

_helm_args_for_external() {
  require_cmd() { :; }
  download_verify() { :; }
  kubectl() { :; }
  retry() { :; }
  helm() {
    [ "${1:-}" = "--kubeconfig" ] && {
      shift 2
      printf '%s\n' "$*"
    }
    return 0
  }
  RANCHER_CHART_VERSION=2.15.1-alpha1 \
    RANCHER_IMAGE_TAG_RESOLVED=v2.15.1-alpha1 \
    RANCHER_IMAGE=stgregistry.suse.com/rancher/rancher \
    RANCHER_REPO=rancher-alpha \
    EXTERNAL="$1" \
    helm_install_rancher /tmp/kc rancher.example.com 2>/dev/null
}

@test "external mode sets agentTLSMode=system-store at install" {
  run _helm_args_for_external true
  [[ "$output" == *"agentTLSMode=system-store"* ]]
}

@test "internal mode leaves agentTLSMode at the chart default" {
  run _helm_args_for_external false
  [[ "$output" != *"agentTLSMode"* ]]
}

# --- prime flavour / community cut-off ---------------------------------------
# Whether a build reports itself as Prime is a property of the image, so these
# stub the registry reads and assert only the decision logic.

@test "image_prime_flavour reports prime when the marker is baked in" {
  skopeo() { printf '{"config":{"Env":["RANCHER_VERSION_TYPE=prime"]}}'; }
  export -f skopeo
  [ "$(image_prime_flavour rancher/rancher v2.14.4)" = "prime" ]
}

@test "image_prime_flavour reports community when the marker is empty" {
  skopeo() { printf '{"config":{"Env":["RANCHER_VERSION_TYPE="]}}'; }
  export -f skopeo
  [ "$(image_prime_flavour rancher/rancher v2.15.0)" = "community" ]
}

@test "image_prime_flavour distinguishes a missing tag from an unreadable one" {
  skopeo() { return 1; }
  export -f skopeo
  image_exists() { return 1; }
  [ "$(image_prime_flavour rancher/rancher v9.9.9)" = "missing" ]
  image_exists() { return 2; }
  [ "$(image_prime_flavour rancher/rancher v9.9.9)" = "unknown" ]
}

@test "the community cut-off hint fires for a patch beyond the published line" {
  image_newest_ga() { printf '2.14.3'; }
  run helm_missing_tag_hint rancher/rancher v2.14.4
  [[ "$output" == *"2.14 line only up to 2.14.3"* ]]
  [[ "$output" == *"rancher-prime-ga"* ]]
}

@test "the cut-off hint stays silent at or below the published patch" {
  image_newest_ga() { printf '2.14.3'; }
  [ "$(helm_missing_tag_hint rancher/rancher v2.14.3)" = "" ]
  [ "$(helm_missing_tag_hint rancher/rancher v2.14.2)" = "" ]
}

@test "the cut-off hint is measured per release line, not globally" {
  # 2.14.4 is older than the newest tag overall, so a global comparison would
  # wrongly stay silent; the 2.14 line is what matters.
  image_newest_ga() {
    case "${2:-}" in
      2.14) printf '2.14.3' ;;
      *) printf '2.15.0' ;;
    esac
  }
  run helm_missing_tag_hint rancher/rancher v2.14.4
  [[ "$output" == *"2.14.3"* ]]
}

@test "the cut-off hint only applies to Docker Hub and to real versions" {
  image_newest_ga() { printf '2.14.3'; }
  [ "$(helm_missing_tag_hint registry.rancher.com/rancher/rancher v2.14.4)" = "" ]
  [ "$(helm_missing_tag_hint rancher/rancher v2.15-head)" = "" ]
  [ "$(helm_missing_tag_hint rancher/rancher head)" = "" ]
}

# --- repository scoping ------------------------------------------------------
# `helm search repo <name>` is a keyword search over every configured
# repository. Both staging repos publish a chart called "rancher-prime", so a
# search for the prime channel also returns their rows and an unscoped match
# resolves to a chart the prime repo does not carry.

@test "resolve_chart_version ignores rows from other repositories" {
  local mixed
  mixed="$(
    printf '%s\n' \
      'NAMECHART VERSIONAPP VERSIONDESCRIPTION' \
      'rancher-alpha/rancher-prime	2.15.1-alpha1	v2.15.1-alpha1	Install SUSE Rancher Prime' \
      'rancher-latest/rancher-prime	2.15.0-rc1	v2.15.0-rc1	Install SUSE Rancher Prime' \
      'rancher-prime/rancher	2.14.4	2.14.4	Install Rancher Server' \
      'rancher-prime/rancher	2.14.3	2.14.3	Install Rancher Server'
  )"
  # head must take prime's own newest, not the alpha row that sorts higher
  [ "$(resolve_chart_version rancher-prime head "$mixed")" = "2.14.4" ]
}

@test "resolve_chart_version ignores a same-named chart in another repository" {
  local mixed
  mixed="$(
    printf '%s\n' \
      'NAMECHART VERSIONAPP VERSIONDESCRIPTION' \
      'rancher-alpha/rancher-prime	2.13.2-alpha3	v2.13.2-alpha3	Install SUSE Rancher Prime' \
      'rancher-prime/rancher	2.14.4	2.14.4	Install Rancher Server'
  )"
  # 2.13.2 exists only as another repo's chart, so prime cannot satisfy it
  [ "$(resolve_chart_version rancher-prime 2.13.2 "$mixed")" = "" ]
}

@test "resolve_chart_version keeps the channels apart in a shared search" {
  local mixed
  mixed="$(
    printf '%s\n' \
      'NAMECHART VERSIONAPP VERSIONDESCRIPTION' \
      'rancher-alpha/rancher	2.15.1-alpha1	v2.15.1-alpha1	Install Rancher Server' \
      'rancher-latest/rancher	2.15.0-rc5	v2.15.0-rc5	Install Rancher Server' \
      'rancher-prime/rancher	2.14.4	2.14.4	Install Rancher Server'
  )"
  [ "$(resolve_chart_version rancher-alpha 2.15 "$mixed")" = "2.15.1-alpha1" ]
  [ "$(resolve_chart_version rancher-latest 2.15 "$mixed")" = "2.15.0-rc5" ]
  [ "$(resolve_chart_version rancher-prime head "$mixed")" = "2.14.4" ]
}

# --- bare minor on a community channel ---------------------------------------
# Docker Hub publishes vX.Y.Z and vX.Y-head but never a bare vX.Y, so passing a
# bare minor through would ask for a tag that cannot exist.

@test "image_tag_is_valid accepts the tags a registry can hold" {
  for t in head v2.15-head 2.15.0-rc5 v1.35.2-k3s1 _weird 1.2.3_4; do
    run image_tag_is_valid "$t"
    [ "$status" -eq 0 ] || {
      echo "rejected a legal tag: $t"
      false
    }
  done
}

@test "image_tag_is_valid rejects a kubernetes build-metadata version" {
  run image_tag_is_valid "v1.35.2+k3s1"
  [ "$status" -ne 0 ]
}

@test "image_tag_is_valid rejects an empty tag, a bad first character or a slash" {
  for t in "" "-leading" ".leading" "a/b" "a:b" "a b"; do
    run image_tag_is_valid "$t"
    [ "$status" -ne 0 ] || {
      echo "accepted an illegal tag: '$t'"
      false
    }
  done
}

@test "image_exists calls an unusable tag missing rather than inconclusive" {
  # skopeo answers "invalid reference format", which matches none of the 404
  # patterns, so without the grammar check this would downgrade to a warning.
  run image_exists rancher/k3s "v1.35.2+k3s1"
  [ "$status" -eq 1 ]
}

@test "tag_is_bare_minor recognises a plain minor, with or without the v" {
  run tag_is_bare_minor 2.14
  [ "$status" -eq 0 ]
  run tag_is_bare_minor v2.14
  [ "$status" -eq 0 ]
}

@test "tag_is_bare_minor rejects a patch, a suffix or a name" {
  for t in 2.14.3 v2.14.3 v2.15-head 2.15.0-rc5 head latest; do
    run tag_is_bare_minor "$t"
    [ "$status" -ne 0 ] || {
      echo "expected literal: $t"
      false
    }
  done
}

@test "a community bare minor resolves to the chart version" {
  [ "$(resolve_image_tag '' 2.14.3 2.14)" = "v2.14.3" ]
  [ "$(resolve_image_tag '' 2.15.0 v2.15)" = "v2.15.0" ]
}

@test "a community exact pin or rolling tag is still passed through" {
  [ "$(resolve_image_tag '' 2.14.3 2.14.3)" = "v2.14.3" ]
  [ "$(resolve_image_tag '' 2.15.0 head)" = "head" ]
  [ "$(resolve_image_tag '' 2.15.0 v2.15-head)" = "v2.15-head" ]
}

@test "a pinned-image channel is unaffected by the bare-minor rule" {
  [ "$(resolve_image_tag stgregistry.suse.com/rancher/rancher 2.14.4-rc1 2.14)" = "v2.14.4-rc1" ]
}

# --- image tag override ------------------------------------------------------
# A branch head ships no chart of its own, so it can only be tested against the
# newest chart of the line it came from. The two do not share a version, so the
# pairing has to be stated rather than derived.

_resolve_with_override() {
  RANCHER_REPO=rancher-alpha RANCHER_IMAGE_TAG=head
  freshness_maybe_promote() { :; }
  require_cmd() { :; }
  retry() { :; }
  helm() { :; }
  helm_verify_image() { :; }
  fetch_index_entries() { :; }
  resolve_chart_version() { printf '2.15.1-alpha1'; }
  helm_resolve_version
}

@test "an image tag override replaces the resolved tag and keeps the chart" {
  RANCHER_IMAGE_TAG_OVERRIDE=v2.15.1-965e189-head
  _resolve_with_override
  [ "$RANCHER_IMAGE_TAG_RESOLVED" = "v2.15.1-965e189-head" ]
  [ "$RANCHER_CHART_VERSION" = "2.15.1-alpha1" ]
}

@test "without an override the tag still comes from the chart version" {
  unset RANCHER_IMAGE_TAG_OVERRIDE
  _resolve_with_override
  [ "$RANCHER_IMAGE_TAG_RESOLVED" = "v2.15.1-alpha1" ]
}

@test "an empty override is ignored rather than blanking the tag" {
  RANCHER_IMAGE_TAG_OVERRIDE=""
  _resolve_with_override
  [ "$RANCHER_IMAGE_TAG_RESOLVED" = "v2.15.1-alpha1" ]
}

@test "a full reference override moves the registry as well as the tag" {
  RANCHER_IMAGE_TAG_OVERRIDE=rancher/rancher:head
  _resolve_with_override
  [ "$RANCHER_IMAGE" = "rancher/rancher" ]
  [ "$RANCHER_IMAGE_TAG_RESOLVED" = "head" ]
  [ "$RANCHER_CHART_VERSION" = "2.15.1-alpha1" ]
}

@test "a full reference override accepts a registry host" {
  RANCHER_IMAGE_TAG_OVERRIDE=docker.io/rancher/rancher:v2.15-head
  _resolve_with_override
  [ "$RANCHER_IMAGE" = "docker.io/rancher/rancher" ]
  [ "$RANCHER_IMAGE_TAG_RESOLVED" = "v2.15-head" ]
}

@test "a bare tag override leaves the channel registry in place" {
  RANCHER_IMAGE_TAG_OVERRIDE=v2.15.1-965e189-head
  _resolve_with_override
  [ "$RANCHER_IMAGE" = "stgregistry.suse.com/rancher/rancher" ]
  [ "$RANCHER_IMAGE_TAG_RESOLVED" = "v2.15.1-965e189-head" ]
}

# --- untruncated search rows -------------------------------------------------
#
# helm truncates table columns to 50 characters and marks the cut with a literal
# "...", which silently corrupted any chart named after a commit: the ellipsis
# ended up in the chart version and the image tag, and the install then asked a
# registry for a tag that cannot exist.

@test "helm_search_charts asks helm not to truncate the columns" {
  helm() { printf 'helm %s\n' "$*"; }
  run helm_search_charts rancher-latest
  [ "$status" -eq 0 ]
  [[ "$output" == *"--max-col-width=0"* ]]
}

@test "helm_search_charts scopes the search to the repository's rancher chart" {
  helm() { printf 'helm %s\n' "$*"; }
  run helm_search_charts rancher-alpha
  [[ "$output" == *"rancher-alpha/rancher"* ]]
  [[ "$output" == *"--devel"* ]]
  [[ "$output" == *"--versions"* ]]
}

@test "helm_search_charts yields nothing rather than failing when helm errors" {
  helm() { return 1; }
  run helm_search_charts rancher-latest
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- resolve_chart_version: pinning a chart the channel filter excludes -------

@test "an exact commit-tagged pin resolves even though it is not an -rc" {
  local search
  search="$(
    printf '%s\n' \
      'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
      'rancher-latest/rancher	2.15.1-c7913dce4e586d7b87cf73bbf6443d953bd184f7-head	x	Install Rancher Server' \
      'rancher-latest/rancher	2.15.1-30739f3ee72a3390477afd1a6540bb25a2b93517-head	x	Install Rancher Server'
  )"
  [ "$(resolve_chart_version rancher-latest 2.15.1-c7913dce4e586d7b87cf73bbf6443d953bd184f7-head "$search")" \
    = "2.15.1-c7913dce4e586d7b87cf73bbf6443d953bd184f7-head" ]
}

@test "an exact pin tolerates a leading v" {
  [ "$(resolve_chart_version rancher-latest v2.12.5-rc10 "$SEARCH_LATEST")" = "2.12.5-rc10" ]
}

@test "an exact pin never crosses into another repository's chart" {
  local search
  search="$(
    printf '%s\n' \
      'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
      'rancher-alpha/rancher	2.15.1-only-in-alpha	x	Install Rancher Server'
  )"
  [ -z "$(resolve_chart_version rancher-latest 2.15.1-only-in-alpha "$search")" ]
}

@test "a suffixed tag that matches nothing exactly still falls through to the filter" {
  # 2.12.5-rc99 is not published; the -rc filter then picks the line's newest rc,
  # which is the behaviour that existed before exact pinning was added.
  [ "$(resolve_chart_version rancher-latest 2.12.5-rc99 "$SEARCH_LATEST")" = "2.12.5-rc10" ]
}

@test "a bare minor still means the newest rc, not an exact match" {
  [ "$(resolve_chart_version rancher-latest 2.12 "$SEARCH_LATEST")" = "2.12.5-rc10" ]
}

# --- helm_channel_line_hint --------------------------------------------------
#
# rancher-latest selects -rc and rancher-alpha selects -alpha, so a line that is
# published but has not reached that stage resolves to nothing. Saying only "no
# chart version matches" points away from the answer, because the version is in
# the listing in a shape the channel does not select.

@test "the hint names the shapes the line does carry, and where the build lives" {
  local search
  search="$(
    printf '%s\n' \
      'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
      'rancher-latest/rancher	2.15.1-c7913dce4e586d7b87cf73bbf6443d953bd184f7-head	x	Install Rancher Server' \
      'rancher-latest/rancher	2.16.0-ff28ae6aea8dcb820bcc2ff8bfd1bc45d4e2ee65-head	x	Install Rancher Server'
  )"
  run helm_channel_line_hint rancher-latest 2.15 "$search"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2.15 line is in rancher-latest but has no release chart yet"* ]]
  [[ "$output" == *"2.15.1-c7913dce4e586d7b87cf73bbf6443d953bd184f7-head"* ]]
  [[ "$output" == *"--channel-source prime --version 2.15"* ]]
  [[ "$output" == *"--repo rancher-alpha"* ]]
  # A chart from another line is not evidence about this one.
  [[ "$output" != *"2.16.0"* ]]
}

@test "the hint points an alpha miss at the rc channel" {
  local search
  search="$(
    printf '%s\n' \
      'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
      'rancher-alpha/rancher	2.13.8-rc1	x	Install Rancher Server'
  )"
  run helm_channel_line_hint rancher-alpha 2.13 "$search"
  [[ "$output" == *"has no -alpha chart yet"* ]]
  [[ "$output" == *"--channel-source prime --version 2.13"* ]]
  [[ "$output" == *"--repo rancher-latest"* ]]
}

@test "the hint stays silent when the line is genuinely absent" {
  run helm_channel_line_hint rancher-latest 2.99 "$SEARCH_LATEST"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the hint stays silent for a channel that has no shape filter" {
  run helm_channel_line_hint rancher-prime-ga 2.99 "$SEARCH_PRIME"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the hint matches a full patch pin as well as a bare minor" {
  local search
  search="$(
    printf '%s\n' \
      'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
      'rancher-latest/rancher	2.15.1-c7913dce4e586d7b87cf73bbf6443d953bd184f7-head	x	Install Rancher Server'
  )"
  run helm_channel_line_hint rancher-latest 2.15.1 "$search"
  [[ "$output" == *"2.15.1 line is in rancher-latest"* ]]
}

@test "the hint does not treat a different minor as the same line" {
  local search
  search="$(
    printf '%s\n' \
      'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
      'rancher-latest/rancher	2.150.0-head	x	Install Rancher Server'
  )"
  run helm_channel_line_hint rancher-latest 2.15 "$search"
  [ -z "$output" ]
}

# --- chart / server line skew ------------------------------------------------
#
# A chart and a server image are versioned separately, and neither version string
# says which line the other is on. The server states its own line in
# CATTLE_CHART_DEFAULT_BRANCH, so read that and compare.

@test "chart_release_line reads the line off both head chart shapes" {
  [ "$(chart_release_line 2.16.0-b29c3a6-head)" = "2.16" ]
  [ "$(chart_release_line 2.15-842907d326ea023d373b40e0b2dca7093b4f1c07-head)" = "2.15" ]
}

@test "chart_release_line reads the line off releases and pre-releases" {
  [ "$(chart_release_line 2.14.5-rc2)" = "2.14" ]
  [ "$(chart_release_line 2.15.1-alpha1)" = "2.15" ]
  [ "$(chart_release_line 2.13.8)" = "2.13" ]
  [ "$(chart_release_line v2.13.8)" = "2.13" ]
}

@test "chart_release_line says nothing for a version that names no line" {
  [ -z "$(chart_release_line head)" ]
  [ -z "$(chart_release_line '')" ]
}

@test "image_chart_line reads the catalog branch off the image config" {
  image_env() { printf 'dev-v2.16'; }
  [ "$(image_chart_line rancher/rancher head)" = "2.16" ]
  image_env() { printf 'release-v2.14'; }
  [ "$(image_chart_line rancher/rancher v2.14.5-rc2)" = "2.14" ]
}

@test "image_chart_line says nothing for an unreadable or unrecognised image" {
  image_env() { printf ''; }
  [ -z "$(image_chart_line rancher/rancher head)" ]
  image_env() { printf 'main'; }
  [ -z "$(image_chart_line rancher/rancher head)" ]
}

@test "helm_line_skew_hint is silent when the lines agree" {
  [ -z "$(helm_line_skew_hint 2.14.5-rc2 2.14 2.14)" ]
}

@test "helm_line_skew_hint is silent when either line is unknown" {
  [ -z "$(helm_line_skew_hint 2.14.5-rc2 2.14 '')" ]
  [ -z "$(helm_line_skew_hint head '' 2.16)" ]
}

@test "helm_line_skew_hint names both lines and which chart to use" {
  # The live case: branches-metadata points master at the release-2.15 chart
  # channel while rancher/rancher:head is built from dev-v2.16.
  run helm_line_skew_hint 2.15-842907d326ea023d373b40e0b2dca7093b4f1c07-head 2.15 2.16
  [ "$status" -eq 0 ]
  [[ "$output" == *"is on the 2.15 line but the server carries the 2.16 chart catalog"* ]]
  [[ "$output" == *"use the 2.16 chart"* ]]
}

@test "helm_check_chart_line warns on a skew and is quiet on a match" {
  RANCHER_IMAGE=rancher/rancher
  RANCHER_IMAGE_TAG_RESOLVED=head
  RANCHER_CHART_VERSION=2.15-abc-head
  image_env() { printf 'dev-v2.16'; }
  run helm_check_chart_line
  [ "$status" -eq 0 ]
  [[ "$output" == *"server carries the 2.16 chart catalog"* ]]

  image_env() { printf 'dev-v2.15'; }
  run helm_check_chart_line
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "helm_check_chart_line stays quiet when image checks are skipped" {
  RANCHER_IMAGE=rancher/rancher
  RANCHER_IMAGE_TAG_RESOLVED=head
  RANCHER_CHART_VERSION=2.15-abc-head
  image_env() { printf 'dev-v2.16'; }
  MUSTER_SKIP_IMAGE_CHECK=1 run helm_check_chart_line
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- head resolution on a channel of commit-named charts ---------------------
#
# The release team is consolidating every Prime pre-release chart into one
# channel, where a head chart is X.Y.Z-<sha>-head. The sha carries no order, so
# version sort picks the highest hex rather than the newest build: rancher-latest
# resolves `head` to a chart published on 14 August because ffbd1cc9 outranks
# b29c3a6 as a string. The line still comes from the version sort; the build
# comes from the index date.

@test "resolve_head_pick returns a release winner untouched" {
  [ "$(resolve_head_pick 2.13.0-rc2 '')" = "2.13.0-rc2" ]
  [ "$(resolve_head_pick 2.14.4 'anything')" = "2.14.4" ]
}

@test "resolve_head_pick takes the newest head chart of the winner's line" {
  local dates
  dates="$(printf '%s\n' \
    '0|2.16.0-ffbd1cc9-head|2026-08-14T15:42:29Z' \
    '0|2.16.0-b29c3a6-head|2026-09-01T14:43:51Z' \
    '0|2.15.2-a90f264-head|2026-09-01T16:06:40Z')"
  [ "$(resolve_head_pick 2.16.0-ffbd1cc9-head "$dates")" = "2.16.0-b29c3a6-head" ]
}

@test "resolve_head_pick keeps the version-sort answer with no dates" {
  [ "$(resolve_head_pick 2.16.0-ffbd1cc9-head '')" = "2.16.0-ffbd1cc9-head" ]
}

@test "resolve_head_pick keeps the version-sort answer when its line has no dated row" {
  local dates
  dates="$(printf '%s\n' '0|2.15.2-a90f264-head|2026-09-01T16:06:40Z')"
  [ "$(resolve_head_pick 2.16.0-ffbd1cc9-head "$dates")" = "2.16.0-ffbd1cc9-head" ]
}

@test "resolve_head_pick does not cross lines to a newer head chart" {
  # 2.12 publishes more often than 2.16, so the newest chart in the channel by
  # date is a 2.12 one. "head" still means the newest line.
  local dates
  dates="$(printf '%s\n' \
    '0|2.16.0-b29c3a6-head|2026-09-01T14:43:51Z' \
    '0|2.12.14-3af2829-head|2026-09-01T16:11:39Z')"
  [ "$(resolve_head_pick 2.16.0-b29c3a6-head "$dates")" = "2.16.0-b29c3a6-head" ]
}

@test "resolve_head_pick handles the per-branch head chart shape" {
  local dates
  dates="$(printf '%s\n' \
    '0|2.15-aaa-head|2026-08-01T00:00:00Z' \
    '0|2.15-bbb-head|2026-09-01T00:00:00Z')"
  [ "$(resolve_head_pick 2.15-aaa-head "$dates")" = "2.15-bbb-head" ]
}

@test "resolve_chart_version head orders commit charts by date when given them" {
  local search dates
  search="$(printf '%s\n' \
    'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
    'rancher-latest/rancher	2.16.0-ffbd1cc9-head	x	Install Rancher Server' \
    'rancher-latest/rancher	2.16.0-b29c3a6-head	x	Install Rancher Server')"
  dates="$(printf '%s\n' \
    '0|2.16.0-ffbd1cc9-head|2026-08-14T15:42:29Z' \
    '0|2.16.0-b29c3a6-head|2026-09-01T14:43:51Z')"
  [ "$(resolve_chart_version rancher-latest head "$search" "$dates")" = "2.16.0-b29c3a6-head" ]
  # Without dates the answer is exactly what it was before.
  [ "$(resolve_chart_version rancher-latest head "$search")" = "2.16.0-ffbd1cc9-head" ]
}

# --- the consolidated Prime pre-release channel ------------------------------

@test "rancher-latest selects an alpha once the line has no rc" {
  # The release team is moving the Prime alphas into this channel. Until they
  # arrive this changes nothing, because the channel carries none.
  local search
  search="$(printf '%s\n' \
    'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
    'rancher-latest/rancher	2.15.1-alpha1	x	Install Rancher Server')"
  [ "$(resolve_chart_version rancher-latest 2.15 "$search")" = "2.15.1-alpha1" ]
}

@test "rancher-latest still prefers the rc when a line has both" {
  local search
  search="$(printf '%s\n' \
    'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
    'rancher-latest/rancher	2.15.1-alpha1	x	Install Rancher Server' \
    'rancher-latest/rancher	2.15.1-rc2	x	Install Rancher Server')"
  [ "$(resolve_chart_version rancher-latest 2.15 "$search")" = "2.15.1-rc2" ]
}

@test "rancher-latest still ignores a head chart for a bare minor" {
  local search
  search="$(printf '%s\n' \
    'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
    'rancher-latest/rancher	2.16.0-b29c3a6-head	x	Install Rancher Server')"
  [ -z "$(resolve_chart_version rancher-latest 2.16 "$search")" ]
}

@test "head prefers a final release over its own release candidate" {
  # sort -V ranks 2.15.1-rc2 above 2.15.1, because the suffix makes the string
  # longer. The GA was published two days after the rc, so it is the newer
  # chart and the one "head" means.
  local search
  search="$(printf '%s\n' \
    'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
    'rancher-com-rc/rancher	2.15.1-rc2	x	Install Rancher Server' \
    'rancher-com-rc/rancher	2.15.1	x	Install Rancher Server' \
    'rancher-com-rc/rancher	2.15.0	x	Install Rancher Server')"
  [ "$(resolve_chart_version rancher-com-rc head "$search")" = "2.15.1" ]
}

@test "head still ranks the pre-release ladder correctly" {
  local search
  search="$(printf '%s\n' \
    'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
    'rancher-latest/rancher	2.12.5-rc2	x	Install Rancher Server' \
    'rancher-latest/rancher	2.12.5-rc10	x	Install Rancher Server' \
    'rancher-latest/rancher	2.12.5-alpha9	x	Install Rancher Server')"
  [ "$(resolve_chart_version rancher-latest head "$search")" = "2.12.5-rc10" ]
}

@test "head still takes the newest line, release or not" {
  local search
  search="$(printf '%s\n' \
    'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
    'rancher-latest/rancher	2.15.1	x	Install Rancher Server' \
    'rancher-latest/rancher	2.16.0-9a46e2a-head	x	Install Rancher Server')"
  [ "$(resolve_chart_version rancher-latest head "$search")" = "2.16.0-9a46e2a-head" ]
}

# --- the release ladder and line boundaries ----------------------------------
#
# Ordering a chart version is not string ordering, and matching a line is not a
# substring search: "2.1" must not answer with 2.15, and "2.12.5" must not answer
# with 2.12.50. Both rules come from the resolver the Ansible pipeline uses.

@test "a line matches only at a version boundary" {
  local versions
  versions="$(printf '%s\n' 2.1.0 2.1.4 2.15.0 2.15.1-rc1 2.150.0)"
  [ "$(printf '%s\n' "$versions" | versions_on_line 2.1 | tr '\n' ' ')" = "2.1.0 2.1.4 " ]
  [ "$(printf '%s\n' "$versions" | versions_on_line 2.15 | tr '\n' ' ')" = "2.15.0 2.15.1-rc1 " ]
}

@test "a patch line does not swallow a longer patch number" {
  local versions
  versions="$(printf '%s\n' 2.12.5 2.12.5-rc1 2.12.50 2.12.5-hotfix-1)"
  [ "$(printf '%s\n' "$versions" | versions_on_line 2.12.5 | tr '\n' ' ')" = "2.12.5 2.12.5-rc1 2.12.5-hotfix-1 " ]
}

@test "resolve_chart_version never crosses into a longer line number" {
  local search
  search="$(printf '%s\n' \
    'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
    'rancher-prime/rancher	2.15.0	2.15.0	Install Rancher Server')"
  [ -z "$(resolve_chart_version rancher-prime 2.1 "$search")" ]
  [ "$(resolve_chart_version rancher-prime 2.15 "$search")" = "2.15.0" ]
}

@test "resolve_chart_version never answers a patch with a longer patch" {
  local search
  search="$(printf '%s\n' \
    'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
    'rancher-prime/rancher	2.12.50	2.12.50	Install Rancher Server')"
  [ -z "$(resolve_chart_version rancher-prime 2.12.5 "$search")" ]
}

@test "the ladder ranks GA above rc above alpha above anything else" {
  local versions
  versions="$(printf '%s\n' 2.14.0-hotfix-1 2.14.0-alpha5 2.14.0-rc2 2.14.0-rc10 2.14.0)"
  [ "$(printf '%s\n' "$versions" | highest_version)" = "2.14.0" ]
}

@test "the ladder orders rc10 above rc2 and alpha5 below rc2" {
  [ "$(printf '%s\n' 2.14.0-rc2 2.14.0-rc10 | highest_version)" = "2.14.0-rc10" ]
  [ "$(printf '%s\n' 2.14.0-alpha5 2.14.0-rc2 | highest_version)" = "2.14.0-rc2" ]
}

@test "a hotfix never sorts above an rc of the same base" {
  run version_ahead 2.14.0-hotfix-1 2.14.0-rc2
  [ "$status" -ne 0 ]
  version_ahead 2.14.0-rc2 2.14.0-hotfix-1
  version_ahead 2.14.0 2.14.0-hotfix-1
}

@test "the ladder keeps numeric patches in numeric order" {
  [ "$(printf '%s\n' 2.13.9 2.13.10 | highest_version)" = "2.13.10" ]
}

@test "resolve_chart_version prefers GA over a same-base rc and hotfix" {
  local search
  search="$(printf '%s\n' \
    'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
    'rancher-prime/rancher	2.14.3-hotfix-64aa.1	2.14.3-hotfix-64aa.1	Install Rancher Server' \
    'rancher-prime/rancher	2.14.3-rc2	2.14.3-rc2	Install Rancher Server' \
    'rancher-prime/rancher	2.14.3	2.14.3	Install Rancher Server')"
  [ "$(resolve_chart_version rancher-prime 2.14.3 "$search")" = "2.14.3" ]
}

@test "resolve_chart_version ranks an rc above an alpha on a no-filter channel" {
  local search
  search="$(printf '%s\n' \
    'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
    'rancher-prime/rancher	2.14.4-alpha7	2.14.4-alpha7	Install Rancher Server' \
    'rancher-prime/rancher	2.14.4-rc1	2.14.4-rc1	Install Rancher Server')"
  [ "$(resolve_chart_version rancher-prime 2.14 "$search")" = "2.14.4-rc1" ]
}

@test "a line request ignores a commit-named head chart on a no-filter channel" {
  # A head chart is a new identity on every commit, so a fixed input resolving to
  # one would deploy a different build on every run.
  local search
  search="$(printf '%s\n' \
    'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
    'rancher-prime/rancher	2.13.4-abc1234-head	x	Install Rancher Server' \
    'rancher-prime/rancher	2.13.3	2.13.3	Install Rancher Server')"
  [ "$(resolve_chart_version rancher-prime 2.13 "$search")" = "2.13.3" ]
}

@test "head takes the newest line and that line's newest release when it has no head" {
  local search
  search="$(printf '%s\n' \
    'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
    'rancher-prime/rancher	2.14.6	2.14.6	Install Rancher Server' \
    'rancher-prime/rancher	2.15.1	2.15.1	Install Rancher Server')"
  [ "$(resolve_chart_version rancher-prime head "$search")" = "2.15.1" ]
}

# --- prime channel fan-out ---------------------------------------------------
#
# A prime row asks all three Prime channels: the GA in rancher-prime-ga once it
# ships, an rc in rancher-latest before that, an alpha in rancher-alpha before
# that. The GA channel is not optional, because charts.optimus stopped receiving
# final Prime releases at 2.14.3.

# _prime_index <channel=rows> ... - stub the index reader for the Prime channels.
_prime_index() {
  PRIME_ROWS=("$@")
  fetch_index_entries() {
    local row
    for row in "${PRIME_ROWS[@]}"; do
      case "$row" in
        "$1="*) printf '%s\n' "${row#*=}" ;;
      esac
    done
    return 0
  }
}

@test "prime takes the GA channel over an rc published in rancher-latest" {
  _prime_index \
    "rancher-prime-ga=3|2.14.3|2026-08-06T10:00:00Z|v2.14.3" \
    "rancher-latest=2|2.14.3-rc2|2026-08-05T10:00:00Z|v2.14.3-rc2"
  CHANNEL_SOURCE=prime RANCHER_IMAGE_TAG=2.14
  helm_resolve_prime >/dev/null
  [ "$RANCHER_REPO" = "rancher-prime-ga" ]
  [ "$RANCHER_IMAGE_TAG" = "2.14.3" ]
  [ "$RANCHER_PRIME_HEAD_PICK" = "0" ]
}

@test "prime falls back to the newest head build when the minor has no release" {
  # 2.16 has dozens of Prime head charts and no release. A minor ships Community
  # first, so refusing these left the newest minor with no Prime coverage.
  _prime_index \
    "rancher-latest=0|2.16.0-ffbd1cc9-head|2026-08-14T15:42:29Z|v2.16.0-ffbd1cc9-head
0|2.16.0-b29c3a6-head|2026-09-01T14:43:51Z|v2.16.0-b29c3a6-head"
  CHANNEL_SOURCE=prime RANCHER_IMAGE_TAG=2.16
  helm_resolve_prime >/dev/null
  [ "$RANCHER_REPO" = "rancher-latest" ]
  [ "$RANCHER_IMAGE_TAG" = "2.16.0-b29c3a6-head" ]
  [ "$RANCHER_PRIME_HEAD_PICK" = "1" ]
}

@test "prime prefers a release over a fresher head build on the same minor" {
  _prime_index \
    "rancher-prime-ga=3|2.15.1|2026-08-01T00:00:00Z|v2.15.1" \
    "rancher-latest=0|2.15.2-a90f264-head|2026-09-01T00:00:00Z|v2.15.2-a90f264-head"
  CHANNEL_SOURCE=prime RANCHER_IMAGE_TAG=2.15
  helm_resolve_prime >/dev/null
  [ "$RANCHER_IMAGE_TAG" = "2.15.1" ]
  [ "$RANCHER_PRIME_HEAD_PICK" = "0" ]
}

@test "prime-head skips the release and takes the newest head by created date" {
  _prime_index \
    "rancher-prime-ga=3|2.15.1|2026-08-01T00:00:00Z|v2.15.1" \
    "rancher-latest=0|2.15.2-zzz9999-head|2026-08-20T00:00:00Z|v2.15.2-zzz9999-head
0|2.15.2-aaa1111-head|2026-09-02T00:00:00Z|v2.15.2-aaa1111-head"
  CHANNEL_SOURCE=prime-head RANCHER_IMAGE_TAG=2.15
  helm_resolve_prime >/dev/null
  [ "$RANCHER_REPO" = "rancher-latest" ]
  [ "$RANCHER_IMAGE_TAG" = "2.15.2-aaa1111-head" ]
  [ "$RANCHER_PRIME_HEAD_PICK" = "1" ]
}

@test "prime-head fails when the minor has releases but no head build" {
  _prime_index "rancher-prime-ga=3|2.15.1|2026-08-01T00:00:00Z|v2.15.1"
  CHANNEL_SOURCE=prime-head RANCHER_IMAGE_TAG=2.15
  run helm_resolve_prime
  [ "$status" -ne 0 ]
  [[ "$output" == *"no Prime head build for the 2.15 line"* ]]
}

@test "prime refuses a tag that is not a minor line" {
  CHANNEL_SOURCE=prime RANCHER_IMAGE_TAG=v2.14.3
  run helm_resolve_prime
  [ "$status" -ne 0 ]
  [[ "$output" == *"--channel-source prime requires a minor line such as v2.14 (got 'v2.14.3')"* ]]
}

@test "prime fails when no Prime channel carries the line" {
  _prime_index "rancher-latest=2|2.14.3-rc2|2026-08-05T10:00:00Z|v2.14.3-rc2"
  CHANNEL_SOURCE=prime RANCHER_IMAGE_TAG=2.99
  run helm_resolve_prime
  [ "$status" -ne 0 ]
  [[ "$output" == *"no Prime release or head build for the 2.99 line"* ]]
}

# --- prime-ga and community-ga -----------------------------------------------
#
# A GA row reads one edition's release channel and only final X.Y.Z, so the
# answer always shipped. The chart supplies the image tag, so the run leaves
# rancherImageTag to the chart rather than deriving it.

# _ga_stub <rows> - stub the index reader and every impure call the GA resolver
# makes, so it runs offline.
_ga_stub() {
  GA_ROWS="$1"
  fetch_index_entries() { printf '%s\n' "$GA_ROWS"; }
  require_cmd() { :; }
  retry() { :; }
  helm() { :; }
  helm_verify_image() { :; }
  helm_check_chart_line() { :; }
}

@test "the GA kinds map to the edition's own release channel" {
  [ "${MUSTER_GA_CHANNEL[prime-ga]}" = "rancher-prime-ga" ]
  [ "${MUSTER_GA_CHANNEL[community-ga]}" = "rancher-com-rc" ]
  [ "$(repo_url "${MUSTER_GA_CHANNEL[prime-ga]}")" = "https://charts.rancher.com/server-charts/prime" ]
  [ "$(repo_url "${MUSTER_GA_CHANNEL[community-ga]}")" = "https://releases.rancher.com/server-charts/latest" ]
}

@test "prime-ga picks only a final release, never an rc or a head build" {
  _ga_stub '3|2.14.4|2026-08-10T00:00:00Z|v2.14.4
3|2.14.6|2026-09-01T00:00:00Z|v2.14.6
2|2.14.7-rc1|2026-09-05T00:00:00Z|v2.14.7-rc1
0|2.14.7-abc-head|2026-09-06T00:00:00Z|v2.14.7-abc-head'
  CHANNEL_SOURCE=prime-ga RANCHER_IMAGE_TAG=v2.14
  helm_resolve_ga >/dev/null
  [ "$RANCHER_REPO" = "rancher-prime-ga" ]
  [ "$RANCHER_CHART_VERSION" = "2.14.6" ]
  [ "$RANCHER_IMAGE_TAG" = "v2.14.6" ]
  [ "$RANCHER_IMAGE_TAG_RESOLVED" = "v2.14.6" ]
  [ "$RANCHER_IMAGE_TAG_FROM_CHART" = "1" ]
  [ "$RANCHER_CHART_RELEASED" = "2026-09-01" ]
}

@test "community-ga reads the community release channel and leaves the image unqualified" {
  _ga_stub '3|2.13.3|2026-06-01T00:00:00Z|v2.13.3'
  CHANNEL_SOURCE=community-ga RANCHER_IMAGE_TAG=2.13
  helm_resolve_ga >/dev/null
  [ "$RANCHER_REPO" = "rancher-com-rc" ]
  [ "$RANCHER_CHART_VERSION" = "2.13.3" ]
  [ "$RANCHER_IMAGE" = "" ]
}

@test "a GA row honours a full version exactly" {
  _ga_stub '3|2.15.1|2026-08-01T00:00:00Z|v2.15.1
3|2.15.2|2026-09-01T00:00:00Z|v2.15.2'
  CHANNEL_SOURCE=prime-ga RANCHER_IMAGE_TAG=v2.15.1
  helm_resolve_ga >/dev/null
  [ "$RANCHER_CHART_VERSION" = "2.15.1" ]
}

@test "a GA row rejects an rc or head build when asked for the line" {
  _ga_stub '2|2.15.2-rc1|2026-09-01T00:00:00Z|v2.15.2-rc1
0|2.15.2-abc-head|2026-09-02T00:00:00Z|v2.15.2-abc-head'
  CHANNEL_SOURCE=prime-ga RANCHER_IMAGE_TAG=2.15
  run helm_resolve_ga
  [ "$status" -ne 0 ]
  [[ "$output" == *"publishes no final release on the 2.15 line"* ]]
  [[ "$output" == *"--channel-source prime"* ]]
}

@test "a GA row dies when the chart appVersion disagrees with its chart version" {
  _ga_stub '3|2.15.1|2026-08-01T00:00:00Z|v2.14.9'
  CHANNEL_SOURCE=prime-ga RANCHER_IMAGE_TAG=2.15
  run helm_resolve_ga
  [ "$status" -ne 0 ]
  [[ "$output" == *"declares appVersion 'v2.14.9'"* ]]
  [[ "$output" == *"numbers its image differently"* ]]
}

@test "a GA row requires the chart appVersion to be exactly v<version>" {
  # The value is taken as written, so a bare 2.15.1 is not the tag the chart
  # publishes even though it normalises to the same version.
  _ga_stub '3|2.15.1|2026-08-01T00:00:00Z|2.15.1'
  CHANNEL_SOURCE=prime-ga RANCHER_IMAGE_TAG=2.15
  run helm_resolve_ga
  [ "$status" -ne 0 ]
  [[ "$output" == *"declares appVersion '2.15.1'"* ]]
  [[ "$output" == *"numbers its image differently"* ]]
}

@test "a GA row tolerates an empty appVersion" {
  _ga_stub '3|2.15.1|2026-08-01T00:00:00Z|'
  CHANNEL_SOURCE=prime-ga RANCHER_IMAGE_TAG=2.15
  helm_resolve_ga >/dev/null
  [ "$RANCHER_CHART_VERSION" = "2.15.1" ]
}

@test "ga_channel_pick rejects a tag that is neither a minor nor a final version" {
  local rows='3|2.14.4|2026-08-10T00:00:00Z|v2.14.4'
  # A pre-release tag used to have its suffix stripped, which turned it into a
  # line request and answered with a different chart than the one asked for.
  run ga_channel_pick rancher-prime-ga 2.14.3-rc1 "$rows"
  [ "$status" -eq 1 ]
  [ -z "$output" ]

  run ga_channel_pick rancher-prime-ga head "$rows"
  [ "$status" -eq 1 ]

  [ "$(ga_channel_pick rancher-prime-ga 2.14 "$rows")" = "rancher-prime-ga|2.14.4|2026-08-10T00:00:00Z|v2.14.4" ]
}

@test "a GA row refuses a pre-release tag instead of resolving its line" {
  _ga_stub '3|2.14.4|2026-08-10T00:00:00Z|v2.14.4'
  CHANNEL_SOURCE=prime-ga RANCHER_IMAGE_TAG=2.14.3-rc1
  run helm_resolve_ga
  [ "$status" -ne 0 ]
  [[ "$output" == *"takes a minor line such as v2.15 or a full version such as v2.15.1 (got '2.14.3-rc1')"* ]]
}

@test "a GA row fails when the exact version is not shipped in that channel" {
  _ga_stub '3|2.15.1|2026-08-01T00:00:00Z|v2.15.1'
  CHANNEL_SOURCE=community-ga RANCHER_IMAGE_TAG=v2.15.9
  run helm_resolve_ga
  [ "$status" -ne 0 ]
  [[ "$output" == *"publishes no final release 2.15.9"* ]]
}

@test "helm_resolve_version dispatches each channel source to its resolver" {
  helm_resolve_metadata() { printf 'metadata'; }
  helm_resolve_ga() { printf 'ga'; }
  helm_resolve_prime() { printf 'prime'; }
  freshness_maybe_promote() { printf 'fixed'; }
  # The rest of the generic path, so a prime pick can run through it.
  helm_search_charts() { :; }
  resolve_chart_version() { printf '2.15.1'; }
  fetch_index_entries() { :; }
  fetch_index_dates() { :; }
  require_cmd() { :; }
  retry() { :; }
  helm_verify_image() { :; }
  helm_check_chart_line() { :; }

  [ "$(CHANNEL_SOURCE=metadata helm_resolve_version)" = "metadata" ]
  [ "$(CHANNEL_SOURCE=prime-ga helm_resolve_version)" = "ga" ]
  [ "$(CHANNEL_SOURCE=community-ga helm_resolve_version)" = "ga" ]
  # A prime pick is already an exact chart, so the keep-fresh probe must not run
  # afterwards and rewrite it; the generic resolution still does.
  RANCHER_REPO=rancher-latest RANCHER_IMAGE_TAG=2.15.1
  [ "$(RANCHER_REPO=rancher-latest RANCHER_IMAGE_TAG=2.15.1 CHANNEL_SOURCE=prime helm_resolve_version)" = "prime" ]
  [ "$(RANCHER_REPO=rancher-latest RANCHER_IMAGE_TAG=2.15.1 CHANNEL_SOURCE=prime-head helm_resolve_version)" = "prime" ]
  [ "$(RANCHER_REPO=rancher-com-alpha RANCHER_IMAGE_TAG=2.15.1 CHANNEL_SOURCE=fixed helm_resolve_version)" = "fixed" ]
}

@test "a GA row omits rancherImageTag from the install when the chart supplies it" {
  helm() { printf '%s\n' "$*"; }
  kubectl() { :; }
  helm_install_cert_manager() { :; }
  require_cmd() { :; }
  RANCHER_REPO=rancher-prime-ga
  RANCHER_CHART_VERSION=2.15.1
  RANCHER_IMAGE=registry.rancher.com/rancher/rancher
  RANCHER_IMAGE_TAG_RESOLVED=v2.15.1
  RANCHER_IMAGE_TAG_FROM_CHART=1
  run helm_install_rancher /tmp/kc rancher.example.com
  [ "$status" -eq 0 ]
  [[ "$output" != *"rancherImageTag="* ]]

  RANCHER_IMAGE_TAG_FROM_CHART=0
  run helm_install_rancher /tmp/kc rancher.example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"rancherImageTag=v2.15.1"* ]]
}

# --- the Prime staleness gate ------------------------------------------------
#
# A Prime row whose newest chart is months old is testing a line that has stopped
# publishing there. Resolution runs before provisioning, so failing costs nothing
# and a green result never means "nothing current was tested".

@test "date_age_days measures elapsed days and says -1 when unparsable" {
  [ "$(date_age_days 2026-08-12 2026-09-05)" = "24" ]
  [ "$(date_age_days 2026-09-05 2026-09-05)" = "0" ]
  [ "$(date_age_days '' 2026-09-05)" = "-1" ]
  [ "$(date_age_days not-a-date 2026-09-05)" = "-1" ]
}

@test "a Prime row fails when its newest chart is past the staleness limit" {
  _prime_index "rancher-latest=2|2.14.3-rc2|2026-05-01T00:00:00Z|v2.14.3-rc2"
  CHANNEL_SOURCE=prime RANCHER_IMAGE_TAG=2.14
  MUSTER_TODAY=2026-09-05 MUSTER_PRIME_MAX_AGE_DAYS=60
  run helm_resolve_prime
  [ "$status" -ne 0 ]
  [[ "$output" == *"newest 2.14 chart in Prime is 2.14.3-rc2, published 2026-05-01 (127 days ago, limit 60)"* ]]
  [[ "$output" == *"stopped publishing to Prime"* ]]
  [[ "$output" == *"Raise MUSTER_PRIME_MAX_AGE_DAYS (or set 0)"* ]]
}

@test "the staleness gate still fires for prime-head" {
  _prime_index "rancher-latest=0|2.14.3-abc-head|2026-05-01T00:00:00Z|v2.14.3-abc-head"
  CHANNEL_SOURCE=prime-head RANCHER_IMAGE_TAG=2.14
  MUSTER_TODAY=2026-09-05 MUSTER_PRIME_MAX_AGE_DAYS=60
  run helm_resolve_prime
  [ "$status" -ne 0 ]
  [[ "$output" == *"newest 2.14 chart in Prime is 2.14.3-abc-head"* ]]
}

@test "a recent chart passes the gate, and a limit of 0 accepts any age" {
  _prime_index "rancher-latest=2|2.14.3-rc2|2026-08-30T00:00:00Z|v2.14.3-rc2"
  CHANNEL_SOURCE=prime RANCHER_IMAGE_TAG=2.14
  MUSTER_TODAY=2026-09-05 MUSTER_PRIME_MAX_AGE_DAYS=60
  helm_resolve_prime >/dev/null
  [ "$RANCHER_IMAGE_TAG" = "2.14.3-rc2" ]

  _prime_index "rancher-latest=2|2.14.3-rc2|2026-05-01T00:00:00Z|v2.14.3-rc2"
  CHANNEL_SOURCE=prime RANCHER_IMAGE_TAG=2.14
  MUSTER_PRIME_MAX_AGE_DAYS=0
  helm_resolve_prime >/dev/null
  [ "$RANCHER_IMAGE_TAG" = "2.14.3-rc2" ]
}

@test "a chart dated in the future is not treated as stale" {
  _prime_index "rancher-latest=2|2.16.3|2026-12-01T00:00:00Z|v2.16.3"
  CHANNEL_SOURCE=prime RANCHER_IMAGE_TAG=2.16
  MUSTER_TODAY=2026-09-05 MUSTER_PRIME_MAX_AGE_DAYS=60
  helm_resolve_prime >/dev/null
  [ "$RANCHER_IMAGE_TAG" = "2.16.3" ]
}

# --- channel fetch semantics: 404 is gone, anything else fails ---------------
#
# A retired channel (404) is skipped so the row keeps working through the Prime
# consolidation. A channel that is merely unreachable might hold the newest
# chart, so resolving from the rest would quietly deploy an older build.

@test "fetch_index_url reads a 200, ignores a 404, and fails otherwise" {
  curl() { printf '%s\n%s' 'apiVersion: v1' 200; }
  [ "$(fetch_index_url https://charts.example/x)" = "apiVersion: v1" ]

  curl() { printf '%s\n%s' '' 404; }
  run fetch_index_url https://charts.example/x
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  curl() { printf '%s\n%s' '' 500; }
  run fetch_index_url https://charts.example/x
  [ "$status" -ne 0 ]

  curl() { return 7; }
  run fetch_index_url https://charts.example/x
  [ "$status" -ne 0 ]
}

@test "a 404 channel is skipped and the rest of the Prime fan-out still resolves" {
  fetch_index_entries() {
    case "$1" in
      rancher-prime-ga) return 0 ;;
      rancher-latest) printf '%s\n' '3|2.15.1|2026-08-27T00:00:00Z|v2.15.1' ;;
      rancher-alpha) printf '' ;;
    esac
  }
  CHANNEL_SOURCE=prime RANCHER_IMAGE_TAG=2.15
  helm_resolve_prime >/dev/null
  [ "$RANCHER_REPO" = "rancher-latest" ]
  [ "$RANCHER_IMAGE_TAG" = "2.15.1" ]
}

@test "an unreachable Prime channel fails the row instead of resolving around it" {
  fetch_index_entries() {
    case "$1" in
      rancher-prime-ga) printf '%s\n' '3|2.15.1|2026-08-27T00:00:00Z|v2.15.1' ;;
      *) return 22 ;;
    esac
  }
  CHANNEL_SOURCE=prime RANCHER_IMAGE_TAG=2.15
  run helm_resolve_prime
  [ "$status" -ne 0 ]
  [[ "$output" == *"failed to fetch chart index from rancher-latest"* ]]
  [[ "$output" == *"charts.optimus.rancher.io/server-charts/latest/index.yaml"* ]]
}

@test "a Prime row fails when every channel answers 404" {
  fetch_index_entries() { printf ''; }
  CHANNEL_SOURCE=prime RANCHER_IMAGE_TAG=2.15
  run helm_resolve_prime
  [ "$status" -ne 0 ]
  [[ "$output" == *"none of rancher-prime-ga, rancher-latest, rancher-alpha served a chart index (every channel answered 404 or was empty)"* ]]
}

# --- mid-run metadata re-read -----------------------------------------------
#
# A metadata row deploys a chart named for one commit from a single-slot channel.
# A republish deletes the previous version, so the chart resolved before
# provisioning can be gone by the time the cluster is up.

@test "a metadata row re-reads its chart index before installing" {
  RANCHER_CHART_URL=https://charts.example/muster-metadata-release-2.15
  RANCHER_REPO=muster-metadata-release-2.15
  RANCHER_CHART_VERSION=2.15-aaa-head
  RANCHER_CHART_RELEASED=2026-09-01
  fetch_index_entries_url() { printf '%s\n' '0|2.15-bbb-head|2026-09-04T10:00:00Z|'; }
  retry() { :; }
  helm_recheck_metadata_chart >/dev/null
  [ "$RANCHER_CHART_VERSION" = "2.15-bbb-head" ]
  [ "$RANCHER_CHART_RELEASED" = "2026-09-04" ]
}

@test "the re-read announces a chart that moved" {
  RANCHER_CHART_URL=https://charts.example/muster-metadata-release-2.15
  RANCHER_REPO=muster-metadata-release-2.15
  RANCHER_CHART_VERSION=2.15-aaa-head
  fetch_index_entries_url() { printf '%s\n' '0|2.15-bbb-head|2026-09-04T10:00:00Z|'; }
  retry() { :; }
  run helm_recheck_metadata_chart
  [ "$status" -eq 0 ]
  [[ "$output" == *"chart moved while the cluster came up: 2.15-aaa-head is gone, deploying 2.15-bbb-head instead"* ]]
}

@test "the re-read leaves the pick alone when the chart has not moved" {
  RANCHER_CHART_URL=https://charts.example/muster-metadata-release-2.15
  RANCHER_REPO=muster-metadata-release-2.15
  RANCHER_CHART_VERSION=2.15-bbb-head
  RANCHER_CHART_RELEASED=2026-09-04
  fetch_index_entries_url() { printf '%s\n' '0|2.15-bbb-head|2026-09-04T10:00:00Z|'; }
  retry() { :; }
  run helm_recheck_metadata_chart
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$RANCHER_CHART_VERSION" = "2.15-bbb-head" ]
}

@test "the re-read keeps the earlier pick when the index cannot be read" {
  RANCHER_CHART_URL=https://charts.example/muster-metadata-release-2.15
  RANCHER_REPO=muster-metadata-release-2.15
  RANCHER_CHART_VERSION=2.15-aaa-head
  fetch_index_entries_url() { return 1; }
  retry() { :; }
  helm_recheck_metadata_chart >/dev/null
  [ "$RANCHER_CHART_VERSION" = "2.15-aaa-head" ]
}

# --- a stopped Community line ------------------------------------------------
#
# A Community line stops receiving patches at some point and the rest ship to
# Prime. A rebuilt -head image proves nothing: head images keep building on both
# registries. The patch gap on final releases is the signal.

@test "index_line_max_final_patch takes the highest shipped patch" {
  local rows='3|2.13.3||v2.13.3
2|2.13.4-rc1||v2.13.4-rc1
0|2.13.4-aaa-head||v2.13.4-aaa-head
3|2.13.13||v2.13.13
3|2.14.9||v2.14.9'
  [ "$(printf '%s\n' "$rows" | index_line_max_final_patch 2.13)" = "13" ]
  [ "$(printf '%s\n' "$rows" | index_line_max_final_patch 2.14)" = "9" ]
  [ "$(printf '%s\n' "$rows" | index_line_max_final_patch 2.99)" = "-1" ]
  [ "$(printf '%s\n' "$rows" | index_line_max_final_patch 2.13)" -gt 0 ]
}

@test "a fixed Community row warns when Prime is ahead on final patches" {
  fetch_index_entries() {
    case "$1" in
      rancher-com-rc) printf '%s\n' '3|2.13.3||v2.13.3' ;;
      rancher-prime-ga) printf '%s\n' '3|2.13.13||v2.13.13' ;;
    esac
  }
  CHANNEL_SOURCE=fixed RANCHER_REPO=rancher-com-rc RANCHER_IMAGE_TAG=v2.13
  run helm_warn_stopped_community
  [ "$status" -eq 0 ]
  [[ "$output" == *"the 2.13 line stopped at Community 2.13.3 while Prime is at 2.13.13"* ]]
  [[ "$output" == *"Use --channel-source prime, or --channel-source metadata"* ]]
}

@test "the stopped-community warning stays quiet when the editions are level" {
  fetch_index_entries() {
    case "$1" in
      rancher-com-rc | rancher-prime-ga) printf '%s\n' '3|2.13.3||v2.13.3' ;;
    esac
  }
  CHANNEL_SOURCE=fixed RANCHER_REPO=rancher-com-rc RANCHER_IMAGE_TAG=v2.13
  run helm_warn_stopped_community
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the warning ignores rc and alpha when Prime is only ahead on a candidate" {
  fetch_index_entries() {
    case "$1" in
      rancher-com-rc) printf '%s\n' '3|2.13.3||v2.13.3' ;;
      rancher-prime-ga) printf '%s\n' '2|2.13.4-rc1||v2.13.4-rc1
1|2.13.4-alpha2||v2.13.4-alpha2' ;;
    esac
  }
  CHANNEL_SOURCE=fixed RANCHER_REPO=rancher-com-rc RANCHER_IMAGE_TAG=v2.13
  run helm_warn_stopped_community
  [ -z "$output" ]
}

@test "the warning is only for fixed Community rows" {
  CHANNEL_SOURCE=prime RANCHER_REPO=rancher-com-rc RANCHER_IMAGE_TAG=v2.13
  run helm_warn_stopped_community
  [ -z "$output" ]

  CHANNEL_SOURCE=fixed RANCHER_REPO=rancher-alpha RANCHER_IMAGE_TAG=v2.13
  run helm_warn_stopped_community
  [ -z "$output" ]

  CHANNEL_SOURCE=fixed RANCHER_REPO=rancher-com-rc RANCHER_IMAGE_TAG=head
  run helm_warn_stopped_community
  [ -z "$output" ]
}

@test "the warning says nothing when an index is unreachable" {
  fetch_index_entries() { return 22; }
  CHANNEL_SOURCE=fixed RANCHER_REPO=rancher-com-rc RANCHER_IMAGE_TAG=v2.13
  run helm_warn_stopped_community
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
