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

  # The Prime staleness gate is exercised by its own tests; the fixtures here
  # carry frozen dates, so pin "now" too rather than letting the wall clock
  # decide whether a row is stale.
  MUSTER_TODAY=2026-09-05

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
# whichever Prime channel currently has it: the GA in rancher-prime-ga once it
# ships, an rc in rancher-latest before that, or an alpha in rancher-alpha for a
# line that has not reached rc. Naming one channel by hand is wrong in every
# direction and changes as a line progresses.
#
# Rows are ladder rows: "rank|version|created|appVersion", with rank 3 a final
# release, 2 an rc, 1 an alpha and 0 anything else. fetch_index_entries is
# stubbed per channel, so the resolver runs offline.

# _prime_index <channel=rows> ... - stub the index reader for the Prime channels.
# The specs are global because fetch_index_entries outlives this call.
_prime_index() {
  PRIME_INDEX_SPECS=("$@")
  fetch_index_entries() {
    local spec
    for spec in "${PRIME_INDEX_SPECS[@]}"; do
      case "$spec" in
        "$1="*) printf '%s\n' "${spec#*=}" ;;
      esac
    done
    return 0
  }
  # A head pick also asks the metadata which branch builds the minor. Keep that
  # offline: an empty answer exercises the release-<line> fallback.
  branches_fetch() { printf '%s' "${BRANCHES_FIXTURE:-}"; }
}

@test "prime picks the rc channel when the line has an rc" {
  _prime_index "rancher-latest=2|2.14.4-rc1|2026-07-30T00:00:00Z|v2.14.4-rc1"
  RANCHER_IMAGE_TAG=2.14
  helm_resolve_prime >/dev/null
  [ "$RANCHER_REPO" = "rancher-latest" ]
  [ "$RANCHER_IMAGE_TAG" = "2.14.4-rc1" ]
}

@test "prime names the channel and the publication date in its log line" {
  _prime_index "rancher-latest=2|2.14.4-rc1|2026-07-30T00:00:00Z|v2.14.4-rc1"
  RANCHER_IMAGE_TAG=2.14
  run helm_resolve_prime
  [ "$status" -eq 0 ]
  [[ "$output" == *"newest 2.14 release is 2.14.4-rc1 in rancher-latest"* ]]
  [[ "$output" == *"published 2026-07-30"* ]]
}

@test "prime falls back to the alpha channel for a line with no rc yet" {
  _prime_index "rancher-alpha=1|2.15.1-alpha1|2026-08-05T00:00:00Z|v2.15.1-alpha1"
  RANCHER_IMAGE_TAG=2.15
  helm_resolve_prime >/dev/null
  [ "$RANCHER_REPO" = "rancher-alpha" ]
  [ "$RANCHER_IMAGE_TAG" = "2.15.1-alpha1" ]
  [ "$RANCHER_PRIME_HEAD_PICK" = "0" ]
}

@test "prime takes the GA channel and prefers a final release over its own rc" {
  # charts.optimus stopped receiving final Prime releases at 2.14.3, so asking
  # the pre-release channels alone answers with an rc of a version that shipped.
  _prime_index \
    "rancher-prime-ga=3|2.14.3|2026-08-06T00:00:00Z|v2.14.3" \
    "rancher-latest=2|2.14.3-rc2|2026-08-05T00:00:00Z|v2.14.3-rc2"
  RANCHER_IMAGE_TAG=2.14
  helm_resolve_prime >/dev/null
  [ "$RANCHER_REPO" = "rancher-prime-ga" ]
  [ "$RANCHER_IMAGE_TAG" = "2.14.3" ]
}

@test "prime rewrites the tag to the exact chart, so no channel filter applies" {
  _prime_index "rancher-alpha=1|2.15.1-alpha1|2026-08-05T00:00:00Z|v2.15.1-alpha1"
  RANCHER_IMAGE_TAG=2.15
  helm_resolve_prime >/dev/null
  # A bare minor would re-select the newest alpha later; the exact version is
  # what makes the row reproduce the same chart on a re-run.
  [ "$RANCHER_IMAGE_TAG" = "2.15.1-alpha1" ]
}

@test "prime asks all three Prime channels, GA first" {
  local seen="$BATS_TEST_TMPDIR/seen"
  fetch_index_entries() {
    printf '%s\n' "$1" >>"$seen"
    if [ "$1" = rancher-latest ]; then
      printf '%s\n' '2|2.14.4-rc1|2026-07-30T00:00:00Z|v2.14.4-rc1'
    fi
    return 0
  }
  RANCHER_IMAGE_TAG=2.14
  helm_resolve_prime >/dev/null
  [ "$(tr '\n' ' ' <"$seen")" = "rancher-prime-ga rancher-latest rancher-alpha " ]
}

@test "prime refuses a version that is not a release line" {
  RANCHER_IMAGE_TAG=2.14.4-rc1
  run helm_resolve_prime
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a minor line"* ]]
  [[ "$output" == *"got '2.14.4-rc1'"* ]]
}

@test "prime refuses a rolling head tag" {
  RANCHER_IMAGE_TAG=head
  run helm_resolve_prime
  [ "$status" -ne 0 ]
  [[ "$output" == *"requires a minor line"* ]]
}

@test "prime fails clearly when no channel carries the line" {
  _prime_index "rancher-latest=2|2.14.4-rc1|2026-07-30T00:00:00Z|v2.14.4-rc1"
  RANCHER_IMAGE_TAG=2.99
  run helm_resolve_prime
  [ "$status" -ne 0 ]
  [[ "$output" == *"no Prime release or head build for the 2.99 line"* ]]
  [[ "$output" == *"rancher-prime-ga, rancher-latest, rancher-alpha"* ]]
}

@test "prime fails when every Prime channel is gone" {
  fetch_index_entries() { printf ''; }
  RANCHER_IMAGE_TAG=2.14
  run helm_resolve_prime
  [ "$status" -ne 0 ]
  [[ "$output" == *"none of rancher-prime-ga, rancher-latest, rancher-alpha served a chart index"* ]]
  [[ "$output" == *"answered 404"* ]]
}

@test "prime ignores whatever --repo was set to" {
  _prime_index "rancher-alpha=1|2.15.1-alpha1|2026-08-05T00:00:00Z|v2.15.1-alpha1"
  RANCHER_REPO=rancher-com-rc
  RANCHER_IMAGE_TAG=2.15
  helm_resolve_prime >/dev/null
  [ "$RANCHER_REPO" = "rancher-alpha" ]
}

@test "prime does not select a head chart when the line has a release" {
  # rancher-latest carries commit-named head charts for 2.15 that are newer by
  # date than the alpha. They are a new identity on every commit, so a row with a
  # release available must not take one.
  _prime_index \
    "rancher-latest=0|2.15.1-6455c9caa998b98d957be801a3a6e3517369f9b7-head|2026-09-14T00:00:00Z|v2.15.1-6455c9ca-head
1|2.15.1-alpha1|2026-08-05T00:00:00Z|v2.15.1-alpha1"
  RANCHER_IMAGE_TAG=2.15
  helm_resolve_prime >/dev/null
  [ "$RANCHER_IMAGE_TAG" = "2.15.1-alpha1" ]
  [ "$RANCHER_REPO" = "rancher-latest" ]
  [ "$RANCHER_PRIME_HEAD_PICK" = "0" ]
}

@test "prime prefers an rc over an alpha published on the same day" {
  _prime_index \
    "rancher-latest=2|2.14.4-rc1|2026-07-30T00:00:00Z|v2.14.4-rc1" \
    "rancher-alpha=1|2.14.4-alpha7|2026-07-30T00:00:00Z|v2.14.4-alpha7"
  RANCHER_IMAGE_TAG=2.14
  helm_resolve_prime >/dev/null
  [ "$RANCHER_IMAGE_TAG" = "2.14.4-rc1" ]
}

# --- a Prime row for a line that has not released ----------------------------
#
# 2.16 carries only commit-named head charts and no release. A minor ships
# Community first, so it has Prime builds for months before its first Prime
# release: refusing those left the newest minor with no Prime coverage. A prime
# row therefore falls back to the newest head build, and only when it has no
# release at all.

@test "prime falls back to the newest head build when the minor has no release" {
  _prime_index \
    "rancher-latest=0|2.16.0-b29c3a6-head|2026-09-01T14:43:51Z|v2.16.0-b29c3a6-head
0|2.16.0-ffbd1cc9-head|2026-08-14T15:42:29Z|v2.16.0-ffbd1cc9-head"
  RANCHER_IMAGE_TAG=2.16
  helm_resolve_prime >/dev/null
  [ "$RANCHER_REPO" = "rancher-latest" ]
  [ "$RANCHER_IMAGE_TAG" = "2.16.0-b29c3a6-head" ]
  [ "$RANCHER_PRIME_HEAD_PICK" = "1" ]
}

@test "prime orders head builds by date, not by sha" {
  # b29c3a6 published after ffbd1cc9, and a string sort would pick the higher
  # hex rather than the newer build.
  _prime_index \
    "rancher-latest=0|2.16.0-ffbd1cc9-head|2026-08-14T15:42:29Z|v2.16.0-ffbd1cc9-head
0|2.16.0-b29c3a6-head|2026-09-01T14:43:51Z|v2.16.0-b29c3a6-head"
  RANCHER_IMAGE_TAG=2.16
  helm_resolve_prime >/dev/null
  [ "$RANCHER_IMAGE_TAG" = "2.16.0-b29c3a6-head" ]
}

@test "the newest head across channels wins on the date" {
  _prime_index \
    "rancher-latest=0|2.16.0-b29c3a6-head|2026-09-01T14:43:51Z|v2.16.0-b29c3a6-head" \
    "rancher-alpha=0|2.16.0-later-head|2026-09-02T09:00:00Z|v2.16.0-later-head"
  RANCHER_IMAGE_TAG=2.16
  helm_resolve_prime >/dev/null
  [ "$RANCHER_REPO" = "rancher-alpha" ]
  [ "$RANCHER_IMAGE_TAG" = "2.16.0-later-head" ]
}

@test "prime prefers any release over a newer head build" {
  _prime_index \
    "rancher-prime-ga=3|2.15.1|2026-08-01T00:00:00Z|v2.15.1" \
    "rancher-latest=0|2.15.2-a90f264-head|2026-09-01T00:00:00Z|v2.15.2-a90f264-head"
  RANCHER_IMAGE_TAG=2.15
  helm_resolve_prime >/dev/null
  [ "$RANCHER_IMAGE_TAG" = "2.15.1" ]
  [ "$RANCHER_PRIME_HEAD_PICK" = "0" ]
}

# --- channel-source prime-head -----------------------------------------------
#
# prime-head skips the release pick and takes the in-flight build directly, so
# it is the kind for testing what is in flight before an rc opens. It is
# deliberately not reproducible.

@test "prime-head takes the head build even when the line has a release" {
  _prime_index \
    "rancher-prime-ga=3|2.15.1|2026-08-01T00:00:00Z|v2.15.1" \
    "rancher-latest=0|2.15.2-a90f264-head|2026-09-01T00:00:00Z|v2.15.2-a90f264-head"
  CHANNEL_SOURCE=prime-head
  RANCHER_IMAGE_TAG=2.15
  helm_resolve_prime >/dev/null
  [ "$RANCHER_REPO" = "rancher-latest" ]
  [ "$RANCHER_IMAGE_TAG" = "2.15.2-a90f264-head" ]
  [ "$RANCHER_PRIME_HEAD_PICK" = "1" ]
}

@test "prime-head fails when the line has releases but no head build" {
  _prime_index "rancher-prime-ga=3|2.15.1|2026-08-01T00:00:00Z|v2.15.1"
  CHANNEL_SOURCE=prime-head
  RANCHER_IMAGE_TAG=2.15
  run helm_resolve_prime
  [ "$status" -ne 0 ]
  [[ "$output" == *"no Prime head build for the 2.15 line"* ]]
}

@test "prime-head still requires a minor line" {
  CHANNEL_SOURCE=prime-head
  RANCHER_IMAGE_TAG=2.15.2-a90f264-head
  run helm_resolve_prime
  [ "$status" -ne 0 ]
  [[ "$output" == *"--channel-source prime-head requires a minor line"* ]]
}

# --- channel-source prime-ga and community-ga --------------------------------
#
# A GA row reads one edition's release channel and only final X.Y.Z, so the
# answer always shipped. It also accepts a full version as a pin.

# _ga_index <rows> - stub the index reader for a GA channel. The GA path reads
# one channel and then adds/updates its helm repo, which is stubbed here.
_ga_index() {
  GA_INDEX_ROWS="$1"
  fetch_index_entries() { printf '%s\n' "$GA_INDEX_ROWS"; }
  helm_verify_image() { :; }
  helm_check_chart_line() { :; }
  require_cmd() { :; }
  retry() { :; }
  helm() { :; }
}

@test "prime-ga takes the newest shipped patch on the line" {
  _ga_index '3|2.14.4|2026-08-10T00:00:00Z|v2.14.4
3|2.14.6|2026-09-01T00:00:00Z|v2.14.6
2|2.14.7-rc1|2026-09-05T00:00:00Z|v2.14.7-rc1
0|2.14.7-abc-head|2026-09-06T00:00:00Z|v2.14.7-abc-head'
  CHANNEL_SOURCE=prime-ga
  RANCHER_IMAGE_TAG=v2.14
  helm_resolve_ga >/dev/null
  [ "$RANCHER_REPO" = "rancher-prime-ga" ]
  [ "$RANCHER_CHART_VERSION" = "2.14.6" ]
  [ "$RANCHER_IMAGE_TAG" = "v2.14.6" ]
  [ "$RANCHER_IMAGE_TAG_RESOLVED" = "v2.14.6" ]
  [ "$RANCHER_IMAGE_TAG_FROM_CHART" = "1" ]
  [ "$RANCHER_CHART_RELEASED" = "2026-09-01" ]
}

@test "community-ga reads the community release channel" {
  _ga_index '3|2.13.3|2026-06-01T00:00:00Z|v2.13.3'
  CHANNEL_SOURCE=community-ga
  RANCHER_IMAGE_TAG=2.13
  helm_resolve_ga >/dev/null
  [ "$RANCHER_REPO" = "rancher-com-rc" ]
  [ "$RANCHER_CHART_VERSION" = "2.13.3" ]
  [ "$RANCHER_IMAGE" = "" ]
}

@test "a GA row honours a full version exactly" {
  _ga_index '3|2.15.1|2026-08-01T00:00:00Z|v2.15.1
3|2.15.2|2026-09-01T00:00:00Z|v2.15.2'
  CHANNEL_SOURCE=prime-ga
  RANCHER_IMAGE_TAG=v2.15.1
  helm_resolve_ga >/dev/null
  [ "$RANCHER_CHART_VERSION" = "2.15.1" ]
}

@test "a GA row rejects an rc or head build for the line" {
  _ga_index '2|2.15.2-rc1|2026-09-01T00:00:00Z|v2.15.2-rc1
0|2.15.2-abc-head|2026-09-02T00:00:00Z|v2.15.2-abc-head'
  CHANNEL_SOURCE=prime-ga
  RANCHER_IMAGE_TAG=2.15
  run helm_resolve_ga
  [ "$status" -ne 0 ]
  [[ "$output" == *"publishes no final release on the 2.15 line"* ]]
  [[ "$output" == *"--channel-source prime"* ]]
}

@test "a GA row fails when the exact version is not shipped there" {
  _ga_index '3|2.15.1|2026-08-01T00:00:00Z|v2.15.1'
  CHANNEL_SOURCE=community-ga
  RANCHER_IMAGE_TAG=v2.15.9
  run helm_resolve_ga
  [ "$status" -ne 0 ]
  [[ "$output" == *"publishes no final release 2.15.9"* ]]
}

@test "a GA row fails when the chart appVersion disagrees with its version" {
  _ga_index '3|2.15.1|2026-08-01T00:00:00Z|v2.14.9'
  CHANNEL_SOURCE=prime-ga
  RANCHER_IMAGE_TAG=2.15
  run helm_resolve_ga
  [ "$status" -ne 0 ]
  [[ "$output" == *"declares appVersion 'v2.14.9'"* ]]
  [[ "$output" == *"numbers its image differently"* ]]
}

@test "a GA row requires appVersion to be exactly v<version>" {
  _ga_index '3|2.15.1|2026-08-01T00:00:00Z|2.15.1'
  CHANNEL_SOURCE=prime-ga
  RANCHER_IMAGE_TAG=2.15
  run helm_resolve_ga
  [ "$status" -ne 0 ]
  [[ "$output" == *"declares appVersion '2.15.1'"* ]]
}

@test "a GA row tolerates an empty appVersion rather than failing" {
  _ga_index '3|2.15.1|2026-08-01T00:00:00Z|'
  CHANNEL_SOURCE=prime-ga
  RANCHER_IMAGE_TAG=2.15
  helm_resolve_ga >/dev/null
  [ "$RANCHER_CHART_VERSION" = "2.15.1" ]
}

@test "an explicit --image-tag still wins in a GA row and sends the tag" {
  _ga_index '3|2.15.1|2026-08-01T00:00:00Z|v2.15.1'
  CHANNEL_SOURCE=prime-ga
  RANCHER_IMAGE_TAG=2.15
  RANCHER_IMAGE_TAG_OVERRIDE=v2.15.1-hotfix9
  helm_resolve_ga >/dev/null
  [ "$RANCHER_IMAGE_TAG_RESOLVED" = "v2.15.1-hotfix9" ]
  [ "$RANCHER_IMAGE_TAG_FROM_CHART" = "0" ]
}

# --- milestone.version: the branch's own release line ------------------------
#
# The dashboard records the milestone each branch builds. It outranks the
# helm.repo-url key, which has to point somewhere even for master and therefore
# cannot state the line: the key names release-2.15 while master builds 2.16.

_BRANCH_META="$(
  cat <<'JSON'
{
  "branches": {
    "master": {
      "e2e": {
        "rancher-image": {
          "registry": "stgregistry.suse.com",
          "namespace": "rancher",
          "name": "rancher",
          "tag": "head"
        },
        "helm": {
          "repo-url": "https://charts.optimus.rancher.io/server-charts/release-2.15"
        }
      },
      "milestone": {
        "version": "v2.16"
      }
    },
    "release-2.15": {
      "e2e": {
        "rancher-image": {
          "namespace": "rancher",
          "name": "rancher",
          "tag": "v2.15-head"
        }
      },
      "milestone": {
        "version": "v2.15"
      }
    }
  }
}
JSON
)"

@test "branches_parse emits the milestone version and the registry" {
  local facts
  facts="$(printf '%s' "$_BRANCH_META" | branches_parse master)"
  [[ "$facts" == *"MILESTONE_VERSION=v2.16"* ]]
  [[ "$facts" == *"METADATA_REGISTRY=stgregistry.suse.com"* ]]
  [[ "$facts" == *"RANCHER_IMAGE=stgregistry.suse.com/rancher/rancher"* ]]
  [[ "$facts" == *"HELM_REPO_URL=https://charts.optimus.rancher.io/server-charts/release-2.15"* ]]
}

@test "branches_parse omits the registry when the image is unqualified" {
  local facts
  facts="$(printf '%s' "$_BRANCH_META" | branches_parse release-2.15)"
  [[ "$facts" == *"RANCHER_IMAGE=rancher/rancher"* ]]
  [[ "$facts" != *"METADATA_REGISTRY="* ]]
}

@test "milestone_chart_line reads the release line off a milestone" {
  [ "$(milestone_chart_line v2.16)" = "2.16" ]
  [ "$(milestone_chart_line 2.16)" = "2.16" ]
  [ "$(milestone_chart_line v2.16.3)" = "2.16" ]
  [ -z "$(milestone_chart_line head)" ]
  [ -z "$(milestone_chart_line '')" ]
}

@test "branches_list_names lists the branch keys" {
  [ "$(printf '%s' "$_BRANCH_META" | branches_list_names | tr '\n' ' ')" = "master release-2.15 " ]
}

@test "branches_for_milestone_line names the branch that builds a minor" {
  [ "$(printf '%s' "$_BRANCH_META" | branches_for_milestone_line 2.16)" = "master" ]
  [ "$(printf '%s' "$_BRANCH_META" | branches_for_milestone_line 2.15)" = "release-2.15" ]
  [ -z "$(printf '%s' "$_BRANCH_META" | branches_for_milestone_line 2.99)" ]
}

@test "metadata_chart_url prefers the milestone over the helm repo-url key" {
  [ "$(metadata_chart_url master https://charts.example/foo v2.16)" \
    = "https://charts.optimus.rancher.io/server-charts/release-2.16" ]
  # Two-argument callers keep the old behaviour.
  [ "$(metadata_chart_url release-2.15 https://charts.example/foo)" = "https://charts.example/foo" ]
  [ "$(metadata_chart_url release-2.13)" = "https://charts.optimus.rancher.io/server-charts/release-2.13" ]
}

@test "a metadata row takes the chart line from the milestone, not the key" {
  FIXTURE="$_BRANCH_META"
  STUB_IMAGE_LINE=""
  unset MUSTER_CHART_LINE
  _resolve head
  [ "$RANCHER_CHART_URL" = "https://charts.optimus.rancher.io/server-charts/release-2.16" ]
  [ "$METADATA_REGISTRY" = "stgregistry.suse.com" ]
}

@test "MUSTER_CHART_LINE=image still takes the line from the image" {
  FIXTURE="$_BRANCH_META"
  STUB_IMAGE_LINE=2.14
  STUB_LINE_INDEX='0|2.14-abc-head|2026-09-01T00:00:00Z'
  MUSTER_CHART_LINE=image _resolve head
  [ "$RANCHER_CHART_URL" = "https://charts.optimus.rancher.io/server-charts/release-2.14" ]
}

# --- prime head picks name their dashboard branch ----------------------------
#
# A head pick rewrites the tag to a chart version, and the branch is normally read
# off that tag. For a minor with no release that is wrong: 2.16 is still built on
# master, so 2.16.0-<sha>-head must not send the run to release-2.16.

@test "a prime head pick names the branch that builds the minor" {
  _prime_index "rancher-latest=0|2.16.0-b29c3a6-head|2026-09-01T14:43:51Z|v2.16.0-b29c3a6-head"
  BRANCHES_FIXTURE="$_BRANCH_META"
  CHANNEL_SOURCE=prime RANCHER_IMAGE_TAG=2.16
  helm_resolve_prime >/dev/null
  [ "$RANCHER_PRIME_HEAD_PICK" = "1" ]
  [ "$DASHBOARD_BRANCH_RESOLVED" = "master" ]
}

@test "a prime head pick falls back to release-<line> without the metadata" {
  _prime_index "rancher-latest=0|2.17.0-abc-head|2026-09-01T14:43:51Z|v2.17.0-abc-head"
  BRANCHES_FIXTURE=""
  CHANNEL_SOURCE=prime RANCHER_IMAGE_TAG=2.17
  helm_resolve_prime >/dev/null
  [ "$DASHBOARD_BRANCH_RESOLVED" = "release-2.17" ]
}

@test "a release pick does not claim a dashboard branch" {
  _prime_index "rancher-prime-ga=3|2.15.1|2026-08-01T00:00:00Z|v2.15.1"
  BRANCHES_FIXTURE="$_BRANCH_META"
  CHANNEL_SOURCE=prime RANCHER_IMAGE_TAG=2.15
  unset DASHBOARD_BRANCH_RESOLVED
  helm_resolve_prime >/dev/null
  [ "$RANCHER_PRIME_HEAD_PICK" = "0" ]
  [ -z "${DASHBOARD_BRANCH_RESOLVED:-}" ]
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

# --- a Prime row reports how old its release is ------------------------------
#
# The parent job drops a Prime row whose newest release has gone quiet, so it
# needs the date. Exported rather than only logged, so a job reads a variable
# instead of parsing output.

@test "prime exports the publication date of the release it picked" {
  _prime_index "rancher-latest=2|2.14.5-rc2|2026-08-28T09:12:00Z|v2.14.5-rc2"
  RANCHER_IMAGE_TAG=2.14
  unset RANCHER_CHART_RELEASED
  helm_resolve_prime >/dev/null
  [ "$RANCHER_CHART_RELEASED" = "2026-08-28" ]
  [ "$RANCHER_IMAGE_TAG" = "2.14.5-rc2" ]
}

@test "plan_age gives the date and its age in days" {
  . "$ROOT/lib/plan.sh"
  [ "$(plan_age 2026-08-28 2026-09-01)" = "2026-08-28  (4 days ago)" ]
}

@test "plan_age falls back to the bare date when it cannot be parsed" {
  . "$ROOT/lib/plan.sh"
  [ "$(plan_age not-a-date 2026-09-01)" = "not-a-date" ]
}
