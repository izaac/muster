#!/usr/bin/env bats
# Unit tests for the metadata channel source (lib/helm.sh + lib/branches.sh):
# muster self-resolving the server image, chart and tag from the dashboard
# branches-metadata.json the way qa-tasks#2410 specifies. The one impure call
# (branches_fetch) and helm are stubbed, so the resolution runs offline.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  . "$ROOT/lib/util.sh"
  # shellcheck source=../lib/buildui.sh
  . "$ROOT/lib/buildui.sh"
  # shellcheck source=../lib/branches.sh
  . "$ROOT/lib/branches.sh"
  # shellcheck source=../lib/helm.sh
  . "$ROOT/lib/helm.sh"

  FIXTURE="$(
    cat <<'JSON'
{
  "branches": {
    "master": {
      "e2e": {
        "rancher-image": {
          "namespace": "rancher",
          "name": "rancher",
          "tag": "head"
        },
        "helm": {
          "repo-url": "https://charts.optimus.rancher.io/server-charts/release-2.15"
        },
        "kube": {
          "version": "v1.35.2+k3s1"
        }
      }
    },
    "release-2.15": {
      "e2e": {
        "rancher-image": {
          "namespace": "rancher",
          "name": "rancher",
          "tag": "v2.15-head"
        }
      }
    },
    "release-2.13": {
      "e2e": {
        "rancher-image": {
          "registry": "stgregistry.suse.com",
          "namespace": "rancher",
          "name": "rancher",
          "tag": "v2.13-head"
        }
      }
    }
  }
}
JSON
  )"
}

# --- metadata_chart_url (pure) -----------------------------------------------

@test "metadata_chart_url prefers the helm repo-url key when present" {
  [ "$(metadata_chart_url release-2.15 https://charts.example/foo)" = "https://charts.example/foo" ]
}

@test "metadata_chart_url derives the optimus per-branch channel when the key is empty" {
  [ "$(metadata_chart_url release-2.13)" = "https://charts.optimus.rancher.io/server-charts/release-2.13" ]
}

# --- metadata_pick_chart (pure) ----------------------------------------------

@test "metadata_pick_chart takes the newest by version sort and drops the header" {
  local search
  search="$(printf '%s\n' \
    'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
    'muster-metadata-release-2.13/rancher	2.13-aaa-head	2.13-aaa-head	Install' \
    'muster-metadata-release-2.13/rancher	2.13-bbb-head	2.13-bbb-head	Install')"
  # sort -V on the sha-tagged heads is deterministic; the point is header removal
  # and repository scoping, not which sha wins.
  run metadata_pick_chart muster-metadata-release-2.13 "$search"
  [ "$status" -eq 0 ]
  [[ "$output" == 2.13-*-head ]]
  [[ "$output" != NAME* ]]
}

@test "metadata_pick_chart ignores a same-named chart from another repository" {
  local search
  search="$(printf '%s\n' \
    'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
    'rancher-latest/rancher	2.13.8-rc1	2.13.8-rc1	Install' \
    'muster-metadata-release-2.13/rancher	2.13-aaa-head	2.13-aaa-head	Install')"
  [ "$(metadata_pick_chart muster-metadata-release-2.13 "$search")" = "2.13-aaa-head" ]
}

# --- helm_resolve_metadata (integration, stubbed) ----------------------------

# _resolve <tag> - drive helm_resolve_metadata with branches_fetch and helm
# stubbed, then leave the RANCHER_* variables set for assertions.
_resolve() {
  branches_fetch() { printf '%s' "$FIXTURE"; }
  helm_verify_image() { :; }
  helm_check_chart_line() { :; }
  require_cmd() { :; }
  # The image states its own chart line; the fixtures below set it per branch.
  image_chart_line() { printf '%s' "${STUB_IMAGE_LINE:-}"; }
  fetch_index_dates_url() { printf '%s' "${STUB_LINE_INDEX:-}"; }
  helm() {
    case "$1 ${2:-}" in
      "search repo")
        local repo="${3%/rancher}"
        printf '%s\n' \
          'NAME	CHART VERSION	APP VERSION	DESCRIPTION' \
          "${repo}/rancher	9.9-sha-head	9.9-sha-head	Install"
        ;;
      *) return 0 ;;
    esac
  }
  RANCHER_IMAGE_TAG="$1"
  CHANNEL_SOURCE=metadata
  unset RANCHER_IMAGE_TAG_OVERRIDE
  helm_resolve_metadata
}

@test "metadata resolves a Prime-registry branch to its stgregistry head" {
  _resolve v2.13-head
  [ "$RANCHER_IMAGE" = "stgregistry.suse.com/rancher/rancher" ]
  [ "$RANCHER_IMAGE_TAG_RESOLVED" = "v2.13-head" ]
  [ "$RANCHER_CHART_URL" = "https://charts.optimus.rancher.io/server-charts/release-2.13" ]
  [ "$RANCHER_CHART_VERSION" = "9.9-sha-head" ]
}

@test "metadata resolves a community branch to the Docker Hub head" {
  _resolve v2.15-head
  [ "$RANCHER_IMAGE" = "rancher/rancher" ]
  [ "$RANCHER_IMAGE_TAG_RESOLVED" = "v2.15-head" ]
  [ "$RANCHER_CHART_URL" = "https://charts.optimus.rancher.io/server-charts/release-2.15" ]
}

@test "metadata takes the chart channel from the helm repo-url key when set" {
  _resolve head
  # master carries a helm.repo-url pointing at release-2.15, so the chart channel
  # follows the key rather than a derived server-charts/master.
  [ "$RANCHER_CHART_URL" = "https://charts.optimus.rancher.io/server-charts/release-2.15" ]
  [ "$RANCHER_IMAGE_TAG_RESOLVED" = "head" ]
}

@test "an image override still wins in metadata mode" {
  RANCHER_IMAGE_TAG_OVERRIDE="rancher/rancher:pinned"
  branches_fetch() { printf '%s' "$FIXTURE"; }
  helm_verify_image() { :; }
  helm_check_chart_line() { :; }
  require_cmd() { :; }
  image_chart_line() { printf ''; }
  fetch_index_dates_url() { printf ''; }
  helm() {
    case "$1 ${2:-}" in
      "search repo")
        local repo="${3%/rancher}"
        printf '%s\n' 'NAME	CHART VERSION' "${repo}/rancher	9.9-sha-head"
        ;;
      *) return 0 ;;
    esac
  }
  RANCHER_IMAGE_TAG=v2.13-head CHANNEL_SOURCE=metadata
  helm_resolve_metadata
  [ "$RANCHER_IMAGE" = "rancher/rancher" ]
  [ "$RANCHER_IMAGE_TAG_RESOLVED" = "pinned" ]
}

# --- channel-source prime ----------------------------------------------------
#
# A Prime row means "the newest Prime release of this line", which lives in
# whichever Prime channel currently has it: an rc in rancher-latest, or an alpha
# in rancher-alpha for a line that has not reached rc. Naming one channel by hand
# is wrong in both directions and changes as a line progresses.

@test "prime picks the rc channel when the line has an rc" {
  freshness_newest_release() { printf '2.14.4-rc1|2026-07-30|rancher-latest'; }
  RANCHER_IMAGE_TAG=2.14
  run helm_resolve_prime
  [ "$status" -eq 0 ]
  [[ "$output" == *"newest 2.14 release is 2.14.4-rc1 in rancher-latest"* ]]
}

@test "prime falls back to the alpha channel for a line with no rc yet" {
  freshness_newest_release() { printf '2.15.1-alpha1|2026-08-05|rancher-alpha'; }
  RANCHER_IMAGE_TAG=2.15
  helm_resolve_prime >/dev/null
  [ "$RANCHER_REPO" = "rancher-alpha" ]
  [ "$RANCHER_IMAGE_TAG" = "2.15.1-alpha1" ]
}

@test "prime rewrites the tag to the exact chart, so no channel filter applies" {
  freshness_newest_release() { printf '2.15.1-alpha1|2026-08-05|rancher-alpha'; }
  RANCHER_IMAGE_TAG=2.15
  helm_resolve_prime >/dev/null
  # A bare minor would re-select the newest alpha later; the exact version is
  # what makes the row reproduce the same chart on a re-run.
  [ "$RANCHER_IMAGE_TAG" = "2.15.1-alpha1" ]
}

@test "prime asks both Prime channels, in rc-then-alpha order" {
  local seen="$BATS_TEST_TMPDIR/seen"
  freshness_newest_release() {
    shift
    printf '%s\n' "$*" >"$seen"
    printf '2.14.4-rc1|2026-07-30|rancher-latest'
  }
  RANCHER_IMAGE_TAG=2.14
  helm_resolve_prime >/dev/null
  [ "$(cat "$seen")" = "rancher-latest rancher-alpha" ]
}

@test "prime refuses a version that is not a release line" {
  RANCHER_IMAGE_TAG=2.14.4-rc1
  run helm_resolve_prime
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs a release line"* ]]
}

@test "prime refuses a rolling head tag" {
  RANCHER_IMAGE_TAG=head
  run helm_resolve_prime
  [ "$status" -ne 0 ]
  [[ "$output" == *"needs a release line"* ]]
}

@test "prime fails clearly when neither channel carries the line" {
  freshness_newest_release() { printf ''; }
  RANCHER_IMAGE_TAG=2.99
  run helm_resolve_prime
  [ "$status" -ne 0 ]
  [[ "$output" == *"no Prime release for the 2.99 line"* ]]
}

@test "prime ignores whatever --repo was set to" {
  freshness_newest_release() { printf '2.15.1-alpha1|2026-08-05|rancher-alpha'; }
  RANCHER_REPO=rancher-com-rc
  RANCHER_IMAGE_TAG=2.15
  helm_resolve_prime >/dev/null
  [ "$RANCHER_REPO" = "rancher-alpha" ]
}

@test "prime does not select a head chart, even when it is the freshest thing published" {
  # rancher-latest carries commit-named head charts for 2.15 that are newer by
  # date than the alpha. They are a new identity on every commit, so a row
  # resolving to one would deploy a different build each run.
  fetch_index_dates() {
    case "$1" in
      rancher-latest)
        printf '%s\n' \
          '0|2.15.1-6455c9caa998b98d957be801a3a6e3517369f9b7-head|2026-08-14T00:00:00Z' \
          '0|2.15.1-ac63bee9ca3b5c28dccfdcb1bc9a57bea7624321-head|2026-08-14T00:00:00Z'
        ;;
      rancher-alpha) printf '%s\n' '0|2.15.1-alpha1|2026-08-05T00:00:00Z' ;;
    esac
  }
  RANCHER_IMAGE_TAG=2.15
  helm_resolve_prime >/dev/null
  [ "$RANCHER_IMAGE_TAG" = "2.15.1-alpha1" ]
  [ "$RANCHER_REPO" = "rancher-alpha" ]
}

@test "prime prefers an rc over an alpha published on the same day" {
  fetch_index_dates() {
    case "$1" in
      rancher-latest) printf '%s\n' '0|2.14.4-rc1|2026-07-30T00:00:00Z' ;;
      rancher-alpha) printf '%s\n' '0|2.14.4-alpha7|2026-07-30T00:00:00Z' ;;
    esac
  }
  RANCHER_IMAGE_TAG=2.14
  helm_resolve_prime >/dev/null
  [ "$RANCHER_IMAGE_TAG" = "2.14.4-rc1" ]
}

@test "prime prefers a final release over its own rc" {
  fetch_index_dates() {
    case "$1" in
      rancher-latest) printf '%s\n' '0|2.13.8-rc1|2026-07-30T00:00:00Z' '1|2.13.8|2026-08-01T00:00:00Z' ;;
      rancher-alpha) printf '' ;;
    esac
  }
  RANCHER_IMAGE_TAG=2.13
  helm_resolve_prime >/dev/null
  [ "$RANCHER_IMAGE_TAG" = "2.13.8" ]
}

# --- a Prime row for a line that has not released ----------------------------
#
# 2.16 today carries only commit-named head charts. A Prime row will not resolve
# to one, because the row would deploy a different build every run, so the error
# has to name what the line does carry instead of stopping at "nothing matched".

@test "newest_head_versions takes the newest head charts by publication date" {
  out="$(printf '%s\n' \
    '0|2.16.0-aaa-head|2026-08-20T00:00:00Z' \
    '0|2.16.0-bbb-head|2026-09-01T00:00:00Z' \
    '0|2.16.0-ccc-head|2026-08-25T00:00:00Z' \
    '0|2.16.0-ddd-head|2026-07-01T00:00:00Z' \
    | newest_head_versions '2[.]16[.]' 3)"
  [ "$out" = "$(printf '2.16.0-bbb-head\n2.16.0-ccc-head\n2.16.0-aaa-head')" ]
}

@test "newest_head_versions ignores releases and other lines" {
  out="$(printf '%s\n' \
    '0|2.16.0-aaa-head|2026-09-01T00:00:00Z' \
    '0|2.16.0-rc1|2026-09-01T00:00:00Z' \
    '0|2.15.2-zzz-head|2026-09-01T00:00:00Z' \
    | newest_head_versions '2[.]16[.]' 3)"
  [ "$out" = "2.16.0-aaa-head" ]
}

@test "newest_head_versions is empty when the line carries no head chart" {
  run newest_head_versions '2[.]16[.]' 3 <<<'1|2.14.4|2026-07-30T00:00:00Z'
  [ -z "$output" ]
}

@test "helm_prime_head_hint names the head charts and how to pin one" {
  fetch_index_dates() {
    case "$1" in
      rancher-latest) printf '%s\n' \
        '0|2.16.0-b29c3a6-head|2026-09-01T00:00:00Z' \
        '0|2.16.0-ff28ae6-head|2026-08-30T00:00:00Z' ;;
      *) printf '' ;;
    esac
  }
  run helm_prime_head_hint 2.16 '2[.]16[.]' rancher-latest rancher-alpha
  [ "$status" -eq 0 ]
  [[ "$output" == *"the 2.16 line is in rancher-latest but has no release yet"* ]]
  [[ "$output" == *"2.16.0-b29c3a6-head"* ]]
  [[ "$output" == *"--repo rancher-latest --version"* ]]
}

@test "helm_prime_head_hint says nothing when the line is absent everywhere" {
  fetch_index_dates() { printf ''; }
  run helm_prime_head_hint 2.99 '2[.]99[.]' rancher-latest rancher-alpha
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "prime points at the head charts when the line has no release" {
  freshness_newest_release() { printf ''; }
  fetch_index_dates() {
    case "$1" in
      rancher-latest) printf '%s\n' '0|2.16.0-b29c3a6-head|2026-09-01T00:00:00Z' ;;
      *) printf '' ;;
    esac
  }
  RANCHER_IMAGE_TAG=2.16
  run helm_resolve_prime
  [ "$status" -ne 0 ]
  [[ "$output" == *"has no release yet"* ]]
  [[ "$output" == *"2.16.0-b29c3a6-head"* ]]
  [[ "$output" == *"no Prime release for the 2.16 line"* ]]
}

# --- muster decides the chart line, the metadata is the input ----------------
#
# The two namespaces cannot line up. A chart channel is always release-X.Y, while
# the dashboard's top branch is called master, so there is no server-charts/master
# to derive and the helm.repo-url key for master has to point somewhere else. It
# currently points at release-2.15 while rancher/rancher:head is dev-v2.16. The
# image states its own line, so take it from there.

@test "metadata_line_chart_url names the line, not the branch" {
  [ "$(metadata_line_chart_url 2.16)" = "https://charts.optimus.rancher.io/server-charts/release-2.16" ]
}

@test "the image's chart line wins over a key pointing at another line" {
  image_chart_line() { printf '2.16'; }
  fetch_index_dates_url() { printf '0|2.16-abc-head|2026-09-01T00:00:00Z'; }
  run metadata_decide_chart_url rancher/rancher head \
    https://charts.optimus.rancher.io/server-charts/release-2.15
  [ "$status" -eq 0 ]
  [[ "$output" == *"server-charts/release-2.16" ]]
}

@test "the key is kept when it already names the image's line" {
  image_chart_line() { printf '2.14'; }
  fetch_index_dates_url() { printf 'should not be consulted'; }
  run metadata_decide_chart_url stg/rancher v2.14-head \
    https://charts.optimus.rancher.io/server-charts/release-2.14
  [ "$output" = "https://charts.optimus.rancher.io/server-charts/release-2.14" ]
}

@test "the key is kept when the image cannot be read" {
  image_chart_line() { printf ''; }
  run metadata_decide_chart_url rancher/rancher head \
    https://charts.optimus.rancher.io/server-charts/release-2.15
  [ "$output" = "https://charts.optimus.rancher.io/server-charts/release-2.15" ]
}

@test "the key is kept when the image's line has no chart channel yet" {
  # After 2.17 opens on master, release-2.17 does not exist on day one.
  image_chart_line() { printf '2.17'; }
  fetch_index_dates_url() { printf ''; }
  run metadata_decide_chart_url rancher/rancher head \
    https://charts.optimus.rancher.io/server-charts/release-2.15
  [ "$status" -eq 0 ]
  [[ "$output" == *"server-charts/release-2.15" ]]
  [[ "$output" == *"has no chart; keeping release-2.15"* ]]
}

@test "MUSTER_CHART_LINE=metadata keeps the key unconditionally" {
  image_chart_line() { printf '2.16'; }
  fetch_index_dates_url() { printf '0|2.16-abc-head|2026-09-01T00:00:00Z'; }
  MUSTER_CHART_LINE=metadata run metadata_decide_chart_url rancher/rancher head \
    https://charts.optimus.rancher.io/server-charts/release-2.15
  [ "$output" = "https://charts.optimus.rancher.io/server-charts/release-2.15" ]
}

@test "the master row resolves against the chart line its image is built from" {
  STUB_IMAGE_LINE=2.16
  STUB_LINE_INDEX='0|2.16-abc-head|2026-09-01T00:00:00Z'
  _resolve head
  [ "$RANCHER_CHART_URL" = "https://charts.optimus.rancher.io/server-charts/release-2.16" ]
  [ "$RANCHER_IMAGE" = "rancher/rancher" ]
  [ "$RANCHER_IMAGE_TAG_RESOLVED" = "head" ]
  # The helm repo alias follows the channel, so a log line names what was used.
  [ "$RANCHER_REPO" = "muster-metadata-release-2.16" ]
}

@test "a release-branch row is unchanged by the decision" {
  STUB_IMAGE_LINE=2.13
  STUB_LINE_INDEX='0|2.13-abc-head|2026-09-01T00:00:00Z'
  _resolve v2.13-head
  [ "$RANCHER_CHART_URL" = "https://charts.optimus.rancher.io/server-charts/release-2.13" ]
  [ "$RANCHER_IMAGE" = "stgregistry.suse.com/rancher/rancher" ]
  [ "$RANCHER_IMAGE_TAG_RESOLVED" = "v2.13-head" ]
}
