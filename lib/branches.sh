#!/usr/bin/env bash
# lib/branches.sh - read the dashboard team's branches-metadata.json.
#
# rancher/dashboard keeps the per-branch E2E matrix (Kubernetes version, Rancher
# image, chart repo) in a single file at the root of that repo. Copying values
# out of it by hand drifts the moment the dashboard team bumps one, so read the
# file instead.
#
# The parser is pure: it takes JSON on stdin and emits KEY=VALUE lines, so the
# shapes are unit-tested without a network. Only branches_fetch talks to GitHub.
#
# Nothing here is allowed to break a run. Every lookup degrades to "no answer"
# on a fetch failure, an unknown branch, or a field the dashboard team has not
# filled in, and the caller keeps its own default.

[ -n "${_MUSTER_BRANCHES_SH:-}" ] && return 0
_MUSTER_BRANCHES_SH=1

MUSTER_BRANCHES_METADATA_URL="${MUSTER_BRANCHES_METADATA_URL:-https://raw.githubusercontent.com/rancher/dashboard/master/branches-metadata.json}"

# branches_parse <branch> - read branches-metadata.json on stdin and emit the
# E2E facts for one branch as KEY=VALUE lines. Emits nothing for an unknown
# branch, and omits any key the file does not carry.
#
# Keys: KUBE_VERSION, RANCHER_IMAGE, RANCHER_IMAGE_TAG, HELM_REPO_URL
#
# The file nests two levels below the branch (e2e.rancher-image.tag), so track
# the object path by brace depth rather than trying to match a fixed shape.
branches_parse() {
  awk -v want="${1:?branch required}" '
    # Track the object path by name so a scalar can be attributed to the object
    # it sits in: depth 2 is "branches", 3 is the branch, 4 the section
    # ("e2e"), 5 the subsection ("rancher-image", "kube", "helm").
    match($0, /"[^"]+"[ \t]*:[ \t]*\{/) {
      k = substr($0, RSTART + 1)
      sub(/".*/, "", k)
      names[++depth] = k
      next
    }
    /^[ \t]*[[{][ \t]*$/ { names[++depth] = ""; next }
    /^[ \t]*[]}]/ {
      if (names[depth] == "rancher-image" && ns != "") {
        print "RANCHER_IMAGE=" (reg == "" ? "" : reg "/") ns "/" nm
        reg = ""; ns = ""; nm = ""
      }
      names[depth--] = ""
      next
    }

    names[3] != want { next }

    match($0, /"[^"]+"[ \t]*:/) {
      k = substr($0, RSTART + 1)
      sub(/".*/, "", k)
      v = substr($0, RSTART + RLENGTH)
      gsub(/^[ \t]+|[ \t]+$|,$/, "", v)
      gsub(/^"|"$/, "", v)
      if (v == "") next

      sect = names[depth]
      if (sect == "kube" && k == "version") print "KUBE_VERSION=" v
      else if (sect == "helm" && k == "repo-url") print "HELM_REPO_URL=" v
      else if (sect == "rancher-image") {
        if (k == "registry") reg = v
        else if (k == "namespace") ns = v
        else if (k == "name") nm = v
        else if (k == "tag") print "RANCHER_IMAGE_TAG=" v
      }
    }
  '
}

# branches_field <branch> <key> - one value from the metadata, or nothing.
# Fetches on every call; the file is a few kilobytes and a run reads it twice at
# most, so a cache would cost more than it saves.
branches_field() {
  local branch="${1:?branch required}" key="${2:?key required}"
  branches_fetch | branches_parse "$branch" \
    | sed -n "s/^${key}=//p" | head -1
}

# branches_fetch - GET branches-metadata.json, empty on any failure.
branches_fetch() {
  local ca
  local -a args=(-fsSL --max-time 15)
  ca="$(ca_bundle)"
  [ -n "$ca" ] && args+=(--cacert "$ca")
  command -v curl >/dev/null 2>&1 || return 0
  curl "${args[@]}" "$MUSTER_BRANCHES_METADATA_URL" 2>/dev/null || true
}

# branches_k3s_image <rancher_tag> - the k3d node image the dashboard team runs
# E2E on for the release line this Rancher tag belongs to, or nothing.
#
# Testing the UI on a different Kubernetes version than the suite was written
# against is a needless source of divergence, so prefer their pin over ours.
#
# A Kubernetes version carries its build metadata after a "+" (v1.35.2+k3s1),
# which is not a legal character in an image tag, so the published image uses a
# "-" instead. Translate rather than asking for a tag that cannot exist.
branches_k3s_image() {
  local tag="${1:?tag required}" branch ver
  branch="$(ui_branch_from_tag "$tag" 2>/dev/null)" || return 0
  [ -n "$branch" ] || return 0
  ver="$(branches_field "$branch" KUBE_VERSION)"
  [ -n "$ver" ] || return 0
  printf 'rancher/k3s:%s' "${ver//+/-}"
}

# branches_apply_k3s_image - set K3S_IMAGE from the metadata when the caller has
# not pinned one. An explicit K3S_IMAGE always wins, and an unreachable or
# silent metadata file leaves the driver default in place.
branches_apply_k3s_image() {
  is_true "${MUSTER_IGNORE_BRANCH_METADATA:-}" && return 0
  [ -z "${K3S_IMAGE:-}" ] || return 0
  local img
  img="$(branches_k3s_image "${RANCHER_IMAGE_TAG:-head}")"
  [ -n "$img" ] || return 0
  K3S_IMAGE="$img"
  export K3S_IMAGE
  log_info "k3s image from dashboard branches-metadata: $K3S_IMAGE"
}

# metadata_chart_url <branch> [helm_repo_url] - the head chart channel for a
# branch. The dashboard team's helm.repo-url key wins when it is filled in;
# otherwise the optimus per-branch channel, which publishes that branch's
# X.Y-<sha>-head chart. Pure: the fallback is a fixed URL shape.
metadata_chart_url() {
  local branch="${1:?branch required}" helmurl="${2:-}"
  if [ -n "$helmurl" ]; then
    printf '%s' "$helmurl"
    return 0
  fi
  printf 'https://charts.optimus.rancher.io/server-charts/%s' "$branch"
}
