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

  # helm_install_rancher already passes agentTLSMode=system-store, so Rancher
  # never serves in strict mode. This re-asserts it for a cluster installed by
  # something else (the existing provider) and is a no-op otherwise.
  log_info "external mode: setting agent-tls-mode=system-store"
  retry 20 5 "agent-tls-mode set" -- \
    kubectl --kubeconfig "$kc" patch settings.management.cattle.io agent-tls-mode --type=merge \
    -p '{"value":"system-store"}'

  # A chart installed with no ingress.tls.source uses the default "rancher",
  # which creates the self-signed tls-rancher-ingress CA and stores it in
  # cacerts. Rancher then bakes that CA into every generated downstream manifest
  # as --ca-checksum (cattle-cluster-agent, fleet-agent), and Cloudflare
  # terminates TLS at its edge with its own certificate, so the agent pins a CA
  # that cannot validate the tunnel hostname and loops on TLS handshake
  # failures. agent-tls-mode=system-store does not help: the checksum is
  # additive. Clear it before anything registers, and keep this after every
  # helm upgrade --install of the chart, because a reinstall repopulates it.
  log_info "external mode: clearing cacerts (Cloudflare edge cert)"
  retry 20 5 "cacerts cleared" -- \
    kubectl --kubeconfig "$kc" patch settings.management.cattle.io cacerts --type=merge \
    -p '{"value":""}'
}
