#!/usr/bin/env bats
# Unit tests for lib/ui.sh. Pure helpers only: no registry, no network.
# image_env is stubbed, so these describe the decision rather than any image.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  . "$ROOT/lib/util.sh"
  # shellcheck source=../lib/ui.sh
  . "$ROOT/lib/ui.sh"
  unset MUSTER_UI_OFFLINE
}

# --- ui_is_release -----------------------------------------------------------
# Mirrors Rancher's settings.IsRelease(), which is what "dynamic" branches on.

@test "ui_is_release accepts a released version, with or without a pre-release" {
  for v in v2.15.0 v2.14.3 v2.15.0-rc5 v2.14.0-alpha7; do
    run ui_is_release "$v"
    [ "$status" -eq 0 ] || {
      echo "rejected a release: $v"
      false
    }
  done
}

@test "ui_is_release rejects a head build and anything not version shaped" {
  for v in "v2.15-549c576-head" "head" "master" "" "release-2.15"; do
    run ui_is_release "$v"
    [ "$status" -ne 0 ] || {
      echo "accepted a non-release: $v"
      false
    }
  done
}

# --- ui_cdn_path -------------------------------------------------------------
# The path is a compile-time constant in rancher/rancher, one per branch, so it
# is predicted from the two image values that identify the branch. Confirmed
# against pkg/settings/setting.go on master and release/v2.12 through v2.15.

@test "ui_cdn_path maps a master build to latest, not to master" {
  [ "$(ui_cdn_path master v2.16-abc-head)" = "latest" ]
}

@test "ui_cdn_path takes the release path from the server version minor" {
  [ "$(ui_cdn_path release-2.15 v2.15-abc-head)" = "release-2.15" ]
  [ "$(ui_cdn_path v2.14.4 v2.14-abc-head)" = "release-2.14" ]
  [ "$(ui_cdn_path v2.13.3 v2.13-abc-head)" = "release-2.13" ]
}

@test "ui_cdn_path does not derive the master path from its minor" {
  # master reports v2.16 while no release-2.16 branch exists yet, so deriving
  # the path from the minor alone would name a path that is not published.
  [ "$(ui_cdn_path master v2.16-abc-head)" != "release-2.16" ]
}

@test "ui_cdn_path yields nothing without a usable version" {
  [ "$(ui_cdn_path '' v2.14-abc-head)" = "" ]
  [ "$(ui_cdn_path v2.14.4 '')" = "" ]
  [ "$(ui_cdn_path v2.14.4 garbage)" = "" ]
}

# --- ui_source ---------------------------------------------------------------

@test "a release build serves the UI it embeds" {
  image_env() {
    case "$3" in
      CATTLE_SERVER_VERSION) printf 'v2.15.0' ;;
      CATTLE_DASHBOARD_UI_VERSION) printf 'v2.15.0' ;;
    esac
  }
  [ "$(ui_source rancher/rancher v2.15.0)" = "image" ]
}

@test "a branch head build redirects to the branch path on the CDN" {
  image_env() {
    case "$3" in
      CATTLE_SERVER_VERSION) printf 'v2.15-549c576-head' ;;
      CATTLE_DASHBOARD_UI_VERSION) printf 'release-2.15' ;;
    esac
  }
  [ "$(ui_source rancher/rancher v2.15-head)" = "https://releases.rancher.com/dashboard/release-2.15/index.html" ]
}

@test "a head build that embeds a released UI still redirects to its branch" {
  # v2.14-head embeds the v2.14.4 UI tarball but serves release-2.14, so the
  # embedded value cannot name the path on its own.
  image_env() {
    case "$3" in
      CATTLE_SERVER_VERSION) printf 'v2.14-c394de4-head' ;;
      CATTLE_DASHBOARD_UI_VERSION) printf 'v2.14.4' ;;
    esac
  }
  [ "$(ui_source rancher/rancher v2.14-head)" = "https://releases.rancher.com/dashboard/release-2.14/index.html" ]
}

@test "a master head build redirects to latest, not to master" {
  image_env() {
    case "$3" in
      CATTLE_SERVER_VERSION) printf 'v2.16-73d6cd5-head' ;;
      CATTLE_DASHBOARD_UI_VERSION) printf 'master' ;;
    esac
  }
  [ "$(ui_source rancher/rancher head)" = "https://releases.rancher.com/dashboard/latest/index.html" ]
}

@test "pinning the UI overrides the dynamic choice" {
  image_env() {
    case "$3" in
      CATTLE_SERVER_VERSION) printf 'v2.15-abc-head' ;;
      CATTLE_DASHBOARD_UI_VERSION) printf 'release-2.15' ;;
    esac
  }
  MUSTER_UI_OFFLINE=true
  [ "$(ui_source rancher/rancher v2.15-head)" = "image" ]
}

@test "turning the pin off sends even a release build to the CDN" {
  image_env() {
    case "$3" in
      CATTLE_SERVER_VERSION) printf 'v2.15.0' ;;
      CATTLE_DASHBOARD_UI_VERSION) printf 'release-2.15' ;;
    esac
  }
  MUSTER_UI_OFFLINE=false
  [ "$(ui_source rancher/rancher v2.15.0)" = "https://releases.rancher.com/dashboard/release-2.15/index.html" ]
}

@test "an unreadable image yields no answer rather than a guess" {
  image_env() { printf ''; }
  [ "$(ui_source rancher/rancher v2.15-head)" = "" ]
}

# --- ui_pin_is_free ----------------------------------------------------------
# What a `-head` image embeds is not always its own branch, so pinning is not
# uniformly safe.

@test "pinning is free when the image embeds a branch build" {
  image_env() { printf 'release-2.15'; }
  run ui_pin_is_free rancher/rancher v2.15-head
  [ "$status" -eq 0 ]
  image_env() { printf 'master'; }
  run ui_pin_is_free rancher/rancher head
  [ "$status" -eq 0 ]
}

@test "pinning costs coverage when the image embeds a released UI" {
  image_env() { printf 'v2.14.4'; }
  run ui_pin_is_free rancher/rancher v2.14-head
  [ "$status" -ne 0 ]
}
