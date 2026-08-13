#!/usr/bin/env bash
# lib/import.sh - stand up a second k3d cluster and import it into the management
# Rancher, so airgap testing has a downstream cluster to work with in the one
# place node-driver provisioning cannot help: there is no cloud to reach.
#
# The downstream joins the management cluster's own network rather than creating
# its own. That is how its nodes reach the shared mirror registry by name and how
# its cluster agent reaches the management Rancher. In airgap it is handed the
# same containerd certs.d tree, with no upstream fallback, so every image it pulls
# comes from the mirror, and the registration manifest, which Rancher writes with
# the mirror-prefixed agent image, resolves against what the mirror already holds.

[ -n "${_MUSTER_IMPORT_SH:-}" ] && return 0
_MUSTER_IMPORT_SH=1

# Where a provisioning.cattle.io imported cluster lives.
MUSTER_IMPORT_NAMESPACE="fleet-default"

# import_pick_downstream <mgmt_instance> - first free e2e-<n> that is neither the
# management instance nor an existing k3d cluster, on stdout.
import_pick_downstream() {
  local mgmt="${1:?management instance required}" n candidate existing
  existing="$(k3d cluster list 2>/dev/null | awk 'NR>1{print $1}')"
  for n in 1 2 3 4 5 6 7 8 9; do
    candidate="e2e-${n}"
    [ "$candidate" = "$mgmt" ] && continue
    printf '%s\n' "$existing" | grep -qx "$candidate" && continue
    printf '%s' "$candidate"
    return 0
  done
  die "no free downstream instance (e2e-1..e2e-9 are all taken)"
}

# import_is_downstream <instance> - true when the instance names an imported
# downstream (e2e-<n>, n>=1) rather than the base management instance. A plain
# `muster down --instance e2e` therefore never touches Rancher state.
import_is_downstream() {
  case "${1:?instance required}" in
    e2e-[1-9]) return 0 ;;
    *) return 1 ;;
  esac
}

# import_management_instance - the instance whose Rancher owns the downstreams.
# An explicit --management-instance wins; otherwise the base "e2e" by convention,
# which is what import_pick_downstream assumes when it hands out e2e-<n>.
import_management_instance() {
  printf '%s' "${MANAGEMENT_INSTANCE:-e2e}"
}

# import_teardown - remove an imported downstream's Rancher registration before
# its k3d cluster is deleted, so the management Rancher deregisters the agent
# rather than keeping a dead, unavailable cluster around.
#
# Best-effort throughout: a management cluster that is already gone, or a
# downstream that was never imported, simply leaves the k3d teardown to proceed.
# The registration is deleted first and waited on, because deleting it is what
# drives Rancher to clean up the cluster-side objects; tearing down the k3d
# cluster first would strand them.
import_teardown() {
  local ds="$INSTANCE" mgmt name mkc
  mgmt="$(import_management_instance)"
  [ "$mgmt" = "$ds" ] && return 0
  name="import-${ds}"

  mkc="$(INSTANCE="$mgmt" driver_kubeconfig 2>/dev/null || true)"
  if [ -z "$mkc" ] || [ ! -s "$mkc" ]; then
    log_info "import: no management cluster '$mgmt' to deregister from; removing k3d cluster only"
    return 0
  fi
  if ! kubectl --kubeconfig "$mkc" get clusters.provisioning.cattle.io "$name" \
    -n "$MUSTER_IMPORT_NAMESPACE" >/dev/null 2>&1; then
    return 0
  fi
  log_info "import: deregistering '$name' from management cluster '$mgmt'"
  kubectl --kubeconfig "$mkc" delete clusters.provisioning.cattle.io "$name" \
    -n "$MUSTER_IMPORT_NAMESPACE" --wait=true --timeout=120s >/dev/null 2>&1 \
    || log_warn "import: could not delete registration '$name' (continuing with k3d teardown)"
}

# import_downstream_up <downstream_instance> <mgmt_network> <mgmt_instance> -
# create the downstream k3d cluster on the management network so it shares the
# mirror registry and can reach the management Rancher.
import_downstream_up() {
  local ds="${1:?downstream instance required}"
  local net="${2:?management network required}"
  local mgmt="${3:?management instance required}"

  if k3d cluster list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$ds"; then
    log_info "import: downstream cluster '$ds' already exists, reusing it"
    return 0
  fi

  log_info "import: creating downstream cluster $ds on network $net"
  # Point the k3d driver at the downstream for this one call through temporary
  # environment overrides: INSTANCE names the new cluster, MUSTER_K3D_NETWORK
  # joins it to the management network, and MUSTER_REGISTRY_INSTANCE keeps the
  # registry name pointing at the shared management registry. None of them
  # persists past the call, so the management context is left untouched, and the
  # downstream inherits the same podman-socket, rootless-gate and airgap wiring.
  INSTANCE="$ds" MUSTER_K3D_NETWORK="$net" MUSTER_REGISTRY_INSTANCE="$mgmt" \
    DASHBOARD_DIST="" driver_up
}

# import_registration_url <mgmt_kc> <mgmt_cluster_id> <mgmt_host> - the URL of the
# registration manifest for an imported cluster, on stdout. Prefers the token's
# own status.manifestUrl and falls back to composing it from the token value, so
# a Rancher that has not populated the field yet still yields a usable URL.
import_registration_url() {
  local kc="${1:?mgmt kubeconfig required}" id="${2:?cluster id required}" host="${3:?host required}"
  local url token secret
  # Rancher 2.9+ moved the token value out of the token object and into a Secret
  # it references by status.tokenSecretName, leaving status.token empty and
  # status.manifestUrl carrying the literal template ".../{token}_<id>.yaml".
  # Read the Secret first, and fall back to the deprecated status.token for older
  # Rancher. Either way, nothing is ready until a real token is in hand.
  secret="$(kubectl --kubeconfig "$kc" get clusterregistrationtokens.management.cattle.io -n "$id" \
    -o jsonpath='{.items[0].status.tokenSecretName}' 2>/dev/null || true)"
  if [ -n "$secret" ]; then
    token="$(kubectl --kubeconfig "$kc" get secret "$secret" -n "$id" \
      -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  fi
  if [ -z "${token:-}" ]; then
    token="$(kubectl --kubeconfig "$kc" get clusterregistrationtokens.management.cattle.io -n "$id" \
      -o jsonpath='{.items[0].status.token}' 2>/dev/null || true)"
  fi
  [ -n "${token:-}" ] || return 1

  url="$(kubectl --kubeconfig "$kc" get clusterregistrationtokens.management.cattle.io -n "$id" \
    -o jsonpath='{.items[0].status.manifestUrl}' 2>/dev/null || true)"
  case "$url" in
    '' | *'{'*) printf 'https://%s/v3/import/%s_%s.yaml' "$host" "$token" "$id" ;;
    *) printf '%s' "$url" ;;
  esac
}

# import_register <mgmt_kc> <name> <mgmt_host> - create an imported cluster in
# Rancher and print its registration manifest URL. Waits for Rancher to mint the
# management cluster and its registration token.
import_register() {
  local kc="${1:?mgmt kubeconfig required}" name="${2:?cluster name required}" host="${3:?host required}"
  local ns="$MUSTER_IMPORT_NAMESPACE"

  kubectl --kubeconfig "$kc" apply -f - >/dev/null <<EOF
apiVersion: provisioning.cattle.io/v1
kind: Cluster
metadata:
  name: ${name}
  namespace: ${ns}
spec: {}
EOF

  local id="" url="" i
  for ((i = 1; i <= 60; i++)); do
    id="$(kubectl --kubeconfig "$kc" get clusters.provisioning.cattle.io "$name" -n "$ns" \
      -o jsonpath='{.status.clusterName}' 2>/dev/null || true)"
    [ -n "$id" ] && break
    sleep 2
  done
  [ -n "$id" ] || die "import: Rancher did not create a management cluster for $name"
  log_info "import: management cluster ${id}"

  for ((i = 1; i <= 60; i++)); do
    url="$(import_registration_url "$kc" "$id" "$host" || true)"
    [ -n "$url" ] && break
    sleep 2
  done
  [ -n "$url" ] || die "import: no registration manifest for $id"
  printf '%s' "$url"
}

# import_apply_manifest <downstream_kc> <manifest_url> - fetch the registration
# manifest from the management Rancher and apply it to the downstream cluster.
# The management cert is self-signed, so the fetch is insecure; the manifest
# itself carries the CA checksum the agent validates against.
import_apply_manifest() {
  local kc="${1:?downstream kubeconfig required}" url="${2:?manifest url required}" body
  log_info "import: applying registration manifest to the downstream cluster"
  body="$(curl -skL --max-time 30 "$url")" || die "import: could not fetch $url"
  [ -n "$body" ] || die "import: empty registration manifest from $url"
  # The manifest is a stream of Kubernetes objects. Anything else, an HTML error
  # page or a JSON API error, means the URL resolved to something other than the
  # manifest, so fail on it here with the body in view rather than leaving kubectl
  # to reject it with an opaque "invalid object to validate".
  case "$body" in
    *apiVersion:*) : ;;
    *) die "import: $url did not return a manifest (got: $(printf '%s' "$body" | head -c 200))" ;;
  esac
  printf '%s' "$body" | kubectl --kubeconfig "$kc" apply -f - >/dev/null \
    || die "import: applying the registration manifest failed"
}

# import_wait_active <mgmt_kc> <name> - block until the imported cluster reports
# ready in Rancher. Non-fatal on timeout: the cluster is registered regardless,
# and the agent may just still be pulling.
import_wait_active() {
  local kc="${1:?mgmt kubeconfig required}" name="${2:?cluster name required}"
  local ns="$MUSTER_IMPORT_NAMESPACE" ready="" i
  log_info "import: waiting for the downstream to become Active (agent pulls, then registers)"
  for ((i = 1; i <= 120; i++)); do
    ready="$(kubectl --kubeconfig "$kc" get clusters.provisioning.cattle.io "$name" -n "$ns" \
      -o jsonpath='{.status.ready}' 2>/dev/null || true)"
    if [ "$ready" = "true" ]; then
      log_ok "import: downstream cluster $name is Active"
      return 0
    fi
    sleep 5
  done
  log_warn "import: $name not Active within timeout; inspect cattle-cluster-agent on the downstream"
  return 1
}

# import_run - the whole flow against the current (management) instance.
import_run() {
  [ "$PROVIDER" = k3d ] || die "import needs --provider k3d (got '$PROVIDER')"
  require_cmd k3d
  require_cmd kubectl

  local mgmt="$INSTANCE" mgmt_kc mgmt_host mgmt_net
  mgmt_kc="$(driver_kubeconfig)"
  mgmt_host="$(driver_endpoint)"
  mgmt_net="k3d-${mgmt}"

  if is_true "${AIRGAP:-}"; then
    [ -n "${MIRROR_REGISTRY:-}" ] || die "--airgap needs --registry <host[:port]>"
    airgap_registry_up "$MIRROR_REGISTRY"
    airgap_verify_registry "$MIRROR_REGISTRY" "${MIRROR_INSECURE:-}"
  fi

  local ds="${IMPORT_INSTANCE:-}"
  [ -n "$ds" ] || ds="$(import_pick_downstream "$mgmt")"
  case "$ds" in
    e2e-[0-9]) : ;;
    *) die "import downstream instance must be e2e-<n> (got '$ds')" ;;
  esac
  [ "$ds" = "$mgmt" ] && die "import downstream must differ from the management instance ($mgmt)"

  # The cluster agent connects to server-url; make sure it names the management
  # host the downstream can actually reach on the shared network.
  retry 10 3 "server-url set" -- \
    kubectl --kubeconfig "$mgmt_kc" patch settings.management.cattle.io server-url \
    --type=merge -p "{\"value\":\"https://${mgmt_host}\"}"

  branches_apply_k3s_image
  import_downstream_up "$ds" "$mgmt_net" "$mgmt"

  local ds_kc
  ds_kc="$(INSTANCE="$ds" driver_kubeconfig)"

  # The downstream's cluster agent connects to the management host by name. On a
  # sealed network there is no upstream DNS to resolve it, and driver_up pinned
  # the downstream's own name rather than the one it has to reach, so pin the
  # management host here.
  if is_true "${AIRGAP:-}"; then
    local mgmt_ip
    mgmt_ip="$(INSTANCE="$mgmt" k3d_lb_ip)"
    airgap_pin_hostname "$ds_kc" "$mgmt_ip" "$mgmt_host" || true
  fi

  local name="import-${ds}" url
  url="$(import_register "$mgmt_kc" "$name" "$mgmt_host")"
  import_apply_manifest "$ds_kc" "$url"
  import_wait_active "$mgmt_kc" "$name" || true

  log_ok "import: downstream '${name}' imported from k3d cluster '${ds}'"
  log_info "import: downstream kubeconfig: ${ds_kc}"
  log_info "import: tear down with 'muster down --instance ${ds}'"
}
