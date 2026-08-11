#!/usr/bin/env bash
# lib/ui.sh - work out which dashboard build Rancher will serve.
#
# Rancher does not necessarily serve the UI inside its own image. Two settings
# decide, and the default leaves the choice to the build:
#
#   ui-offline-preferred   true | false | dynamic   (default dynamic)
#   ui-dashboard-index     URL of a remote index.html
#
# On "dynamic" a release build serves the UI it embeds and anything else
# redirects to ui-dashboard-index, so a `-head` image serves a UI that is
# rebuilt continuously and is not identified by the image digest. Two runs of
# the same tag minutes apart can therefore load different UI code, which is a
# real source of unexplained result changes.
#
# Everything needed to predict this is in the image config, so resolve it up
# front rather than discovering it from a failing test.
#
# The helpers are pure apart from image_env and ui_index_fingerprint.

[ -n "${_MUSTER_UI_SH:-}" ] && return 0
_MUSTER_UI_SH=1

MUSTER_DASHBOARD_CDN="${MUSTER_DASHBOARD_CDN:-https://releases.rancher.com/dashboard}"

# image_env <image> <tag> <key> - one environment value from an image config, or
# nothing. Requires skopeo; without it there is no answer rather than a guess.
image_env() {
  local image="${1:?image required}" tag="${2:?tag required}" key="${3:?key required}" cfg
  local -a tls=()
  is_true "${MUSTER_REGISTRY_INSECURE:-}" && tls=(--tls-verify=false)
  command -v skopeo >/dev/null 2>&1 || return 0
  cfg="$(skopeo inspect --config "${tls[@]}" "docker://${image}:${tag}" 2>/dev/null)" || return 0
  printf '%s' "$cfg" \
    | tr ',' '\n' \
    | sed -n "s/.*\"${key}=\([^\"]*\)\".*/\1/p" \
    | head -1
}

# ui_is_release <server_version> - Rancher's own settings.IsRelease(), which is
# what "dynamic" branches on: a version starting with a digit after the v, and
# not a head build. Mirrored rather than approximated, because "contains head"
# is what rules out v2.15-...-head while vX.Y.Z-rc1 stays a release.
ui_is_release() {
  local v="${1:-}"
  case "$v" in
    *head*) return 1 ;;
    v[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

# ui_cdn_path <ui_version> <server_version> - path segment under the dashboard
# CDN that an image's ui-dashboard-index points at, or nothing when it cannot be
# worked out.
#
# The value is a compile-time constant in rancher/rancher pkg/settings, one per
# branch, so it is not carried in the image environment and has to be predicted
# from what is. Two facts do it:
#
#   master           -> "latest"
#   release/vX.Y     -> "release-X.Y"
#
# CATTLE_DASHBOARD_UI_VERSION says which of the two the image came from, because
# only a master build carries the literal "master". A release branch build
# carries either its own branch name or the UI release it was built against
# (v2.15-head has release-2.15, v2.14-head has v2.14.4), so that value alone
# cannot name the path and the minor is taken from the server version instead.
#
# Going the other way and deriving the path from the minor for everything does
# not work: master currently reports v2.16 and no release-2.16 exists, since the
# branch is cut later than the version is bumped.
#
# A "master" path does exist on the CDN and answers 200, which makes it an easy
# wrong answer, but it was last written in February 2020 and still carries the
# old flat asset layout. Live master is "latest".
ui_cdn_path() {
  local ui="${1:-}" server="${2:-}" minor
  case "$ui" in
    '') return 0 ;;
    master)
      printf 'latest'
      return 0
      ;;
  esac
  minor="$(printf '%s' "$server" | sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')"
  [ -n "$minor" ] || return 0
  printf 'release-%s' "$minor"
}

# ui_source <image> <tag> - "image" when Rancher will serve the UI it embeds,
# otherwise the index URL it will redirect to. Empty when the image cannot be
# read.
#
# An explicit MUSTER_UI_OFFLINE of true or false overrides the dynamic choice,
# the same way setting ui-offline-preferred does on a live cluster.
ui_source() {
  local image="${1:?image required}" tag="${2:?tag required}" ver ui path
  case "${MUSTER_UI_OFFLINE:-dynamic}" in
    true)
      printf 'image'
      return 0
      ;;
  esac
  ver="$(image_env "$image" "$tag" CATTLE_SERVER_VERSION)"
  [ -n "$ver" ] || return 0
  if [ "${MUSTER_UI_OFFLINE:-dynamic}" != false ] && ui_is_release "$ver"; then
    printf 'image'
    return 0
  fi
  ui="$(image_env "$image" "$tag" CATTLE_DASHBOARD_UI_VERSION)"
  path="$(ui_cdn_path "$ui" "$ver")"
  [ -n "$path" ] || return 0
  printf '%s/%s/index.html' "$MUSTER_DASHBOARD_CDN" "$path"
}

# ui_pin_is_free <image> <tag> - whether pinning the UI to the image would still
# test the branch's UI.
#
# A `-head` image is built from a branch, but what it embeds is whichever UI the
# build was given, and that is not always the branch: v2.15-head embeds
# release-2.15 while v2.14-head embeds v2.14.4, the last GA build. Pinning the
# first costs nothing and makes the run reproducible; pinning the second
# silently swaps the branch UI for a released one, which is how a UI regression
# gets masked.
ui_pin_is_free() {
  local ui
  ui="$(image_env "${1:?image required}" "${2:?tag required}" CATTLE_DASHBOARD_UI_VERSION)"
  case "$ui" in
    master | release-*) return 0 ;;
    *) return 1 ;;
  esac
}

# ui_index_fingerprint <url> - short hash of a remote index, so two runs can be
# compared. The CDN path carries no version and is rebuilt continuously, so the
# index content is the only thing that identifies which UI was loaded.
ui_index_fingerprint() {
  local url="${1:?url required}" body bundle
  local -a args=(-fsSL --max-time 20)
  local ca
  ca="$(ca_bundle)"
  [ -n "$ca" ] && args+=(--cacert "$ca")
  command -v curl >/dev/null 2>&1 || return 0
  body="$(curl "${args[@]}" "$url" 2>/dev/null)" || return 0
  [ -n "$body" ] || return 0
  # The asset names are content hashed, so hashing the index tracks the UI
  # rather than any header the CDN happens to add.
  bundle="$(printf '%s' "$body" | cksum | awk '{print $1}')"
  printf '%s' "$bundle"
}
