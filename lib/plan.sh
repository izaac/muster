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
  plan_row channel "$RANCHER_REPO"
  plan_row "chart repo" "$RANCHER_CHART_URL"
  plan_row "chart version" "$RANCHER_CHART_VERSION"
  plan_row image "${image}:${tag}"

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

  # A community line stops receiving patches at some point and the rest ship to
  # the prime registries, so say when a newer patch exists somewhere else.
  local hint
  hint="$(helm_missing_tag_hint "$image" "$tag" || true)"
  [ -n "$hint" ] && log_warn "$hint"
  return 0
}
