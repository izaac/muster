#!/usr/bin/env bash
# drivers/existing.sh - point at an already-running cluster.
#
# The caller supplies KUBECONFIG and RANCHER_HOST; up/down are no-ops so the
# core still runs gates + (optional) tunnel + handoff against it. Covers the
# ansible job_type=existing path. Implemented in Phase 4.

[ -n "${_MUSTER_DRIVER_EXISTING_SH:-}" ] && return 0
_MUSTER_DRIVER_EXISTING_SH=1

driver_up() { die "existing driver_up: not implemented (Phase 4)"; }
driver_down() { die "existing driver_down: not implemented (Phase 4)"; }
driver_kubeconfig() { die "existing driver_kubeconfig: not implemented (Phase 4)"; }
driver_endpoint() { die "existing driver_endpoint: not implemented (Phase 4)"; }
