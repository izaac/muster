#!/usr/bin/env bash
# lib/plan.sh - resolve what a run would use, without changing anything.
#
# The two questions asked before every run are "which build is this" and "is it
# Prime", and both were previously only answerable by starting the cluster and
# looking. Neither depends on the cluster existing, so resolve and print them.
#
# Reads registries and chart indexes; creates nothing.

[ -n "${_MUSTER_PLAN_SH:-}" ] && return 0
_MUSTER_PLAN_SH=1

# plan_row <label> <value> - one aligned line of the report.
plan_row() { printf '  %-16s %s\n' "$1" "$2" >&2; }

# plan_age <date> <today> - a date with its age in days, or the date alone when
# the two cannot be compared. Deterministic given its arguments.
plan_age() {
  local d="${1:?date required}" today="${2:?today required}" de te
  de="$(_date_epoch "$d" 2>/dev/null)" || de=""
  te="$(_date_epoch "$today" 2>/dev/null)" || te=""
  if [ -z "$de" ] || [ -z "$te" ]; then
    printf '%s' "$d"
    return 0
  fi
  printf '%s  (%s days ago)' "$d" "$(((te - de) / 86400))"
}

# plan_report - print the resolved plan for the current flags.
#
# Runs the same resolution the install does, so what it prints is what a real
# run would use rather than a re-derivation that could disagree.
plan_report() {
  local image tag flavour k3s note

  helm_resolve_version

  image="${RANCHER_IMAGE:-rancher/rancher}"
  tag="$RANCHER_IMAGE_TAG_RESOLVED"

  log_info "plan only; nothing will be created"
  plan_row provider "$PROVIDER"
  plan_row instance "$INSTANCE"
  plan_row external "$EXTERNAL"
  case "${CHANNEL_SOURCE:-fixed}" in
    fixed) ;;
    metadata) plan_row "channel source" "metadata  (branches-metadata.json decides registry and image)" ;;
    prime) plan_row "channel source" "prime  (newest release of the line; a head build when it has none)" ;;
    prime-head) plan_row "channel source" "prime-head  (newest in-flight build; not reproducible)" ;;
    prime-ga | community-ga) plan_row "channel source" "${CHANNEL_SOURCE}  (shipped releases only; the chart supplies the image tag)" ;;
  esac
  plan_row channel "$RANCHER_REPO"
  plan_row "chart repo" "$RANCHER_CHART_URL"
  plan_row "chart version" "$RANCHER_CHART_VERSION"
  if is_true "${RANCHER_IMAGE_TAG_FROM_CHART:-}"; then
    plan_row image "${image}:${tag}  (from chart appVersion)"
  else
    plan_row image "${image}:${tag}"
  fi
  # Which branch the UI has to come from is not implied by the tag once a head
  # build belongs to a minor with no release: 2.16.0-<sha>-head is built on
  # master, not on a release-2.16 that does not exist yet.
  if [ -n "${DASHBOARD_BRANCH_RESOLVED:-}" ]; then
    plan_row "dashboard branch" "${DASHBOARD_BRANCH_RESOLVED}"
  fi
  # The registry the branch metadata named, which the post-deploy check compares
  # against. Empty means Docker Hub.
  if [ -n "${METADATA_REGISTRY:-}" ]; then
    plan_row "metadata registry" "${METADATA_REGISTRY}"
  fi

  # For a Prime row, how long ago the release was published is what decides
  # whether the row is worth running at all: a line whose newest release has gone
  # quiet is not being developed, and a job that keeps running it reports on
  # nothing. Days are given so the caller does not have to work them out.
  if [ -n "${RANCHER_CHART_RELEASED:-}" ]; then
    plan_row released "$(plan_age "$RANCHER_CHART_RELEASED" "$(today)")"
  fi

  flavour="$(image_prime_flavour "$image" "$tag")"
  case "$flavour" in
    prime) note="Prime-only UI extensions will load" ;;
    community) note="Prime-only UI extensions will NOT load" ;;
    missing) note="this tag is not published in that registry" ;;
    *) note="could not read the image config (skopeo missing, or registry unreachable)" ;;
  esac
  plan_row flavour "$(printf '%s  (%s)' "$flavour" "$note")"

  if [ "$PROVIDER" = k3d ]; then
    if [ -n "${K3S_IMAGE:-}" ]; then
      plan_row "k3s image" "$K3S_IMAGE  (pinned)"
    else
      k3s="$(branches_k3s_image "$RANCHER_IMAGE_TAG")"
      if [ -n "$k3s" ]; then
        plan_row "k3s image" "$k3s  (dashboard branches-metadata)"
      else
        plan_row "k3s image" "driver default"
      fi
    fi
  fi

  if is_true "${EXTERNAL:-}"; then
    plan_row "agent TLS" "system-store  (external mode)"
  else
    plan_row "agent TLS" "chart default"
  fi

  # Which UI gets served is not implied by the image tag, and on a rolling tag it
  # changes between runs, so say it before the run rather than after a result.
  local ui_from
  if [ -n "${DASHBOARD_DIST:-}" ]; then
    plan_row ui "$DASHBOARD_DIST  (mounted over the pod)"
  elif [ "${MUSTER_UI_OFFLINE:-}" = auto ]; then
    # auto is the one mode that cannot be answered before the pod exists: the pin
    # it reads is a build-time env var. Say what deploys and when it is decided.
    plan_row "ui offline" "auto  (deploys true; reconsidered from the running pod)"
    plan_row ui "decided after deploy  (CDN branch UI when a head image pins a released UI)"
  else
    if [ -n "${MUSTER_UI_OFFLINE:-}" ]; then
      plan_row "ui offline" "$MUSTER_UI_OFFLINE"
    fi
    ui_from="$(ui_source "$image" "$tag")"
    case "$ui_from" in
      '') plan_row ui "unknown  (could not read the image config)" ;;
      image) plan_row ui "the image  (a release build serves what it embeds)" ;;
      *)
        plan_row ui "$ui_from"
        if ui_pin_is_free "$image" "$tag"; then
          plan_row "" "rebuilt continuously; --ui-offline pins it to the same branch UI"
        else
          plan_row "" "rebuilt continuously; the image embeds a released UI, so pinning would change what is tested"
        fi
        ;;
    esac
  fi

  # A community line stops receiving patches at some point and the rest ship to
  # the prime registries, so say when a newer patch exists somewhere else.
  local hint
  hint="$(helm_missing_tag_hint "$image" "$tag" || true)"
  [ -n "$hint" ] && log_warn "$hint"
  return 0
}
