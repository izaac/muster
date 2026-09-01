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

@test "index_rancher_dates emits stab|version|created per rancher entry" {
  out="$(printf '%s\n' "$INDEX_LATEST" | index_rancher_dates)"
  [ "$out" = "0|2.14.2-rc1|2026-05-27T10:00:00Z" ]
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
