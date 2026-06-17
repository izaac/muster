#!/usr/bin/env bash
# lib/warmup.sh - provisioning-controller warm-up to avoid the cold-start flake.
# Ported in Phase 3 from k3d-rancher.sh warm_provisioning.

[ -n "${_MUSTER_WARMUP_SH:-}" ] && return 0
_MUSTER_WARMUP_SH=1

# warmup_provisioning - create one throwaway imported cluster (spec:{}, zero
# machines) so the controller warms its informer caches, then delete it.
warmup_provisioning() {
  local kc="$1"
  local name="muster-prov-warmup" ns="fleet-default" mc="" i
  log_info "warm-up: priming provisioning controller (throwaway imported cluster)"

  if ! kubectl --kubeconfig "$kc" apply -f - >/dev/null 2>&1 <<EOF; then
apiVersion: provisioning.cattle.io/v1
kind: Cluster
metadata:
  name: ${name}
  namespace: ${ns}
spec: {}
EOF
    log_warn "warm-up cluster apply failed - skipping prime (tests may cold-start)"
    return 0
  fi

  for ((i = 1; i <= 90; i++)); do
    mc="$(kubectl --kubeconfig "$kc" get clusters.provisioning.cattle.io "$name" -n "$ns" \
      -o jsonpath='{.status.clusterName}' 2>/dev/null || true)"
    [ -n "$mc" ] && break
    sleep 2
  done

  if [ -n "$mc" ]; then
    log_info "warm-up: provisioning controller primed (mgmt mirror ${mc})"
  else
    log_warn "warm-up mgmt mirror not observed in 180s - proceeding anyway"
  fi

  kubectl --kubeconfig "$kc" delete clusters.provisioning.cattle.io "$name" -n "$ns" \
    --wait=true --timeout=120s >/dev/null 2>&1 || true
}
