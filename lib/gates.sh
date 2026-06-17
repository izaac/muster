#!/usr/bin/env bash
# lib/gates.sh - readiness gates run after the chart install.
#
# Provider-blind: everything here talks to the cluster through the driver
# contract (driver_kubeconfig, driver_endpoint) and plain HTTPS. A driver may
# optionally define driver_settle for a substrate-specific quiescence check
# (e.g. k3d node CPU); gates_wait calls it last when present.
#
# Ported from k3d-rancher.sh do_wait (internal-mode gates). External-only steps
# (server-url pin, system-store, warm-up) live in lib/external.sh + lib/warmup.sh.

[ -n "${_MUSTER_GATES_SH:-}" ] && return 0
_MUSTER_GATES_SH=1

# gates_wait - block until Rancher is serving and its controllers are ready.
#
# A driver that ships Rancher itself (e.g. docker standalone, where the
# container IS rancher) may define driver_gate to run provider-specific
# HTTP-only readiness checks; gates_wait delegates to it and skips the
# in-cluster kubectl gates (rollout/webhook/capi) which do not apply. Drivers
# on a real cluster leave driver_gate undefined and get the kubectl path.
gates_wait() {
  local kc host
  kc="$(driver_kubeconfig)"
  host="$(driver_endpoint)"

  if declare -F driver_gate >/dev/null; then
    driver_gate "$host"
  else
    log_info "waiting: rancher deployment rollout"
    kubectl --kubeconfig "$kc" -n cattle-system rollout status deploy/rancher --timeout=600s

    if is_true "${EXTERNAL:-}"; then
      external_apply "$kc" "$host"
    fi

    log_info "waiting: dashboard responds 200"
    retry 20 5 "dashboard HTTP 200" -- \
      sh -c "curl -skI --max-time 5 'https://${host}/dashboard/' | head -1 | grep -q ' 200'"

    # 90 attempts (15 min) covers cold CI runners where CRD apply + webhook chart
    # install saturate the node and gate timing varies run-to-run. Locally ~90s.
    log_info "waiting: rancher-webhook pod ready"
    retry 90 10 "rancher-webhook 1/1 Running" -- \
      sh -c "kubectl --kubeconfig '$kc' -n cattle-system get po -l app=rancher-webhook 2>/dev/null | grep -q '1/1.*Running'"

    # head (>=2.15, Turtles) deploys CAPI into cattle-capi-system; older lines used
    # cattle-provisioning-capi-system. Accept either.
    log_info "waiting: capi-webhook-service exists"
    retry 90 10 "capi-webhook-service" -- \
      sh -c "kubectl --kubeconfig '$kc' -n cattle-capi-system get service capi-webhook-service 2>/dev/null \
        || kubectl --kubeconfig '$kc' -n cattle-provisioning-capi-system get service capi-webhook-service 2>/dev/null"

    # Deeper than the dashboard page: proves the auth provider API is serving.
    log_info "waiting: /v3-public/authProviders/local responds 200"
    retry 20 5 "authProviders API 200" -- \
      sh -c "curl -sk --max-time 5 -o /dev/null -w '%{http_code}' 'https://${host}/v3-public/authProviders/local' | grep -q 200"
  fi

  if declare -F driver_settle >/dev/null; then
    log_info "waiting: substrate to settle"
    driver_settle || log_warn "substrate did not settle in time - proceeding anyway"
  fi

  # warmup_provisioning drives kubectl; only meaningful when the driver
  # exposes a kubeconfig (k3d/existing), not for the docker standalone path.
  if is_true "${EXTERNAL:-}" && [ -n "$kc" ]; then
    warmup_provisioning "$kc"
  fi

  log_ok "rancher ready: https://${host}/dashboard"
}
