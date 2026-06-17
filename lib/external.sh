#!/usr/bin/env bash
# lib/external.sh - external-access patches: server-url pin and
# agent-tls-mode=system-store. Ported in Phase 3 from k3d-rancher.sh do_wait.

[ -n "${_MUSTER_EXTERNAL_SH:-}" ] && return 0
_MUSTER_EXTERNAL_SH=1

# external_apply - point server-url at the public host and set system-store TLS
# BEFORE any downstream cluster registers.
external_apply() {
  local kc="$1" host="$2"

  log_info "external mode: pinning server-url to https://${host}"
  retry 20 5 "server-url set" -- \
    kubectl --kubeconfig "$kc" patch settings.management.cattle.io server-url --type=merge \
    -p "{\"value\":\"https://${host}\"}"

  log_info "external mode: setting agent-tls-mode=system-store"
  retry 20 5 "agent-tls-mode set" -- \
    kubectl --kubeconfig "$kc" patch settings.management.cattle.io agent-tls-mode --type=merge \
    -p '{"value":"system-store"}'
}
