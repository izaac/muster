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
  require_cmd() { :; }
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
  require_cmd() { :; }
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
