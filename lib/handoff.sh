#!/usr/bin/env bash
# lib/handoff.sh - emit consumer handoff in the requested format.
# Phase 1 implements the minimal `env` adapter; cypress/json land in Phase 2.

[ -n "${_MUSTER_HANDOFF_SH:-}" ] && return 0
_MUSTER_HANDOFF_SH=1

# handoff_write <env|cypress|json> - write/print the handoff for a consumer.
# Reads the live cluster facts exported by cmd_up:
#   MUSTER_HOSTNAME MUSTER_KUBECONFIG MUSTER_PASSWORD
handoff_write() {
  local fmt="${1:-env}"
  case "$fmt" in
    env)
      local host="${MUSTER_HOSTNAME:?cmd_up must run first}"
      printf 'TEST_BASE_URL=https://%s/dashboard\n' "$host"
      printf 'RANCHER_HOSTNAME=%s\n' "$host"
      printf 'KUBECONFIG=%s\n' "${MUSTER_KUBECONFIG:-}"
      printf 'TEST_PASSWORD=%s\n' "${MUSTER_PASSWORD:-password1234}"
      ;;
    cypress | json)
      die "handoff_write: '$fmt' adapter is not implemented (Phase 2)"
      ;;
    *)
      die "handoff_write: unknown format '$fmt' (env|cypress|json)"
      ;;
  esac
}
