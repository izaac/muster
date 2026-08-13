#!/usr/bin/env bash
# lib/airgap.sh - point a cluster at a private registry instead of the internet.
#
# A real airgap is two facts, and muster reproduces both:
#
#   1. Every image comes from the mirror. That is a containerd concern, so it is
#      expressed the way containerd expresses it, with a per-registry
#      certs.d/hosts.toml that mirrors each upstream registry onto ours - and,
#      critically, with no upstream fallback, so the mirror is the only place an
#      image can come from.
#   2. The cluster has no route to the internet. The nodes sit on an internal
#      container network, which has no gateway, so nothing running on them can
#      reach anything the mirror does not hold. Published ports still work, so
#      the k3d load balancer stays reachable from the host: the same shape as a
#      private network fronted by a load balancer whose rules let an operator at
#      the UI in, and nothing out.
#
# Without (2), only image pulls are sealed and everything else a server does -
# calling an API, fetching a chart index, phoning home - still reaches out, so a
# behaviour that silently depends on the internet passes as green.
#
# Mirroring at the container runtime rather than through systemDefaultRegistry
# is deliberate. systemDefaultRegistry rewrites the names Rancher asks for, so a
# missing image looks like a Rancher misconfiguration; a runtime mirror leaves
# the names alone, so anything absent from the mirror fails as a plain pull
# error naming the image we forgot. That is the failure we want while we are
# still establishing what a complete mirror contains.
#
# The fallback matters enough to spell out: k3s, handed a registries.yaml, turns
# each mirror into a hosts.toml that also carries "server = <upstream>", which
# containerd tries on a 404. That quietly turns a missing image into an internet
# pull whenever the nodes can reach one, so a gap in the mirror passes as green.
# muster writes the hosts.toml files itself, without the server line, to keep the
# mirror authoritative even if the network around it changes.

[ -n "${_MUSTER_AIRGAP_SH:-}" ] && return 0
_MUSTER_AIRGAP_SH=1

# Registries the mirror stands in for. Every image muster deals with comes from
# one of these, and each keeps its repository path under the mirror, so no
# rewrite rule is needed.
MUSTER_AIRGAP_MIRRORED_REGISTRIES="docker.io quay.io ghcr.io registry.suse.com stgregistry.suse.com registry.rancher.com"

# Name and internal port of the registry muster runs itself.
MUSTER_REGISTRY_NAME_PREFIX="muster-registry"
MUSTER_REGISTRY_PORT=5000

# airgap_registry_name - container name of the registry for this instance.
#
# MUSTER_REGISTRY_INSTANCE overrides which instance the registry name is keyed
# to, defaulting to INSTANCE. An imported downstream cluster runs under its own
# INSTANCE but must reach the management instance's registry, so it sets this to
# the management instance and leaves the name pointing at the shared registry.
airgap_registry_name() { printf '%s-%s' "$MUSTER_REGISTRY_NAME_PREFIX" "${MUSTER_REGISTRY_INSTANCE:-${INSTANCE:-e2e}}"; }

# airgap_registry_host - the mirror as the cluster nodes must address it.
#
# The nodes are containers, so a loopback address is their own, not the host's,
# and a published port belongs to whichever daemon published it. Rather than
# route back out to the host, the registry joins the cluster's own network and
# is addressed by container name, which needs no published port at all and is
# closer to how a real airgapped environment reaches its registry.
airgap_registry_host() {
  local reg="${1:?registry required}"
  case "$reg" in
    localhost:* | 127.0.0.1:* | 0.0.0.0:*) printf '%s:%s' "$(airgap_registry_name)" "$MUSTER_REGISTRY_PORT" ;;
    localhost | 127.0.0.1) printf '%s:%s' "$(airgap_registry_name)" "$MUSTER_REGISTRY_PORT" ;;
    *) printf '%s' "$reg" ;;
  esac
}

# airgap_registry_is_local <registry> - true when the caller means the registry
# muster manages rather than one that already exists somewhere else.
airgap_registry_is_local() {
  case "${1:?registry required}" in
    localhost | localhost:* | 127.0.0.1 | 127.0.0.1:* | 0.0.0.0:*) return 0 ;;
    *) return 1 ;;
  esac
}

# airgap_repo_path <image> - the repository path of an image with any registry
# host stripped, so "stgregistry.suse.com/rancher/rancher" becomes "rancher/
# rancher" and a bare "rancher/rancher" is left alone. A first path element that
# looks like a registry (contains a dot or a colon, or is localhost) is dropped.
#
# This is what an airgapped agent image must be handed. Rancher prefixes
# systemDefaultRegistry onto CATTLE_AGENT_IMAGE, so a fully qualified value would
# become <mirror>/<upstream-host>/rancher/rancher-agent, a path the mirror does
# not carry: the mirror keeps the repository path only. Unlike the server image,
# which containerd redirects by swapping its host, the agent reference is built
# by Rancher and never passes through that host-swap.
airgap_repo_path() {
  local image="${1:?image required}"
  case "${image%%/*}" in
    localhost | localhost:* | *.* | *:*) printf '%s' "${image#*/}" ;;
    *) printf '%s' "$image" ;;
  esac
}

# airgap_registry_up <registry> - ensure the managed registry is running on the
# same container runtime as the cluster, and publish it on the host as well so
# `muster mirror` can fill it from outside.
airgap_registry_up() {
  local reg="${1:?registry required}" name port
  airgap_registry_is_local "$reg" || return 0
  name="$(airgap_registry_name)"
  port="${reg##*:}"
  [ "$port" = "$reg" ] && port="$MUSTER_REGISTRY_PORT"

  if container_cli inspect "$name" >/dev/null 2>&1; then
    container_cli start "$name" >/dev/null 2>&1 || true
    return 0
  fi

  log_info "airgap: starting registry $name on port $port"
  container_cli run -d --name "$name" \
    -p "${port}:${MUSTER_REGISTRY_PORT}" \
    --restart unless-stopped \
    docker.io/library/registry:2 >/dev/null \
    || die "could not start the registry container"

  local attempt=0
  while [ "$attempt" -lt 30 ]; do
    curl -fsS --max-time 2 "http://127.0.0.1:${port}/v2/" >/dev/null 2>&1 && return 0
    attempt=$((attempt + 1))
    sleep 1
  done
  die "registry $name did not become ready"
}

# airgap_registry_attach <network> - put the registry on the cluster network so
# the nodes can reach it by name.
airgap_registry_attach() {
  local net="${1:?network required}" name
  name="$(airgap_registry_name)"
  container_cli inspect "$name" >/dev/null 2>&1 || return 0
  container_cli network connect "$net" "$name" >/dev/null 2>&1 || true
  log_info "airgap: registry $name attached to $net"
}

# airgap_registry_down - remove the managed registry and everything it holds.
airgap_registry_down() {
  local name
  name="$(airgap_registry_name)"
  container_cli inspect "$name" >/dev/null 2>&1 || return 0
  container_cli rm -f "$name" >/dev/null 2>&1 || true
  log_info "airgap: removed registry $name"
}

# Label muster stamps on a network it creates, so teardown only removes its own
# and leaves a network the caller brought (MUSTER_K3D_NETWORK) alone.
MUSTER_NETWORK_LABEL="muster.airgap=1"

# airgap_network_up <network> - ensure the cluster network exists, creating it if
# absent so muster owns it rather than inheriting whatever k3d left behind.
#
# The network is a normal bridge on purpose. A container network created
# --internal has a gateway address but installs no default route, and k3s refuses
# to start without one ("no default routes found in /proc/net/route"), so the
# route has to exist while the node boots. It is removed afterwards by
# airgap_seal_network, which is what actually takes the internet away.
airgap_network_up() {
  local net="${1:?network required}"
  if container_cli network inspect "$net" >/dev/null 2>&1; then
    log_info "airgap: reusing existing network $net"
    return 0
  fi
  container_cli network create --label "$MUSTER_NETWORK_LABEL" "$net" >/dev/null 2>&1 \
    || die "could not create the network $net"
  log_info "airgap: network $net created"
}

# airgap_seal_network <network> - take the default route away from every k3s node
# on the network, so the cluster has no way out.
#
# This is the second half of the airgap, and the half that matters for anything
# that is not an image pull. Without it the nodes sit on a NAT'd bridge and a
# server can still call an API, fetch a chart index or phone home, so a behaviour
# that silently depends on the internet passes as green.
#
# Removing the route rather than firewalling is deliberate. It is one command per
# node, it needs no privilege beyond what the runtime already grants, and it
# leaves everything on the node's own subnet reachable: the mirror by name, the
# other nodes, and the runtime's DNS resolver on the gateway address, which is
# on-link.
#
# The result is verified rather than assumed. Deleting a route can succeed and
# then be undone: if anything restarts the node the runtime rebuilds its network
# namespace with a fresh default route, and an airgap that quietly came back
# online is worse than one that never applied.
#
# The load balancer is left alone. It is the way in, not a cluster node, and the
# published port is the only thing an operator reaches the UI through.
airgap_seal_network() {
  local net="${1:?network required}" node nodes sealed=0 failed=0
  nodes="$(airgap_network_nodes "$net")"
  for node in $nodes; do
    container_cli exec "$node" ip route del default >/dev/null 2>&1 || true
    if airgap_node_is_sealed "$node"; then
      sealed=$((sealed + 1))
    else
      failed=$((failed + 1))
      log_warn "airgap: $node still has a route off the subnet"
    fi
  done
  if [ "$failed" -gt 0 ]; then
    return 1
  fi
  if [ "$sealed" -gt 0 ]; then
    log_info "airgap: sealed $sealed node(s) on $net, no route off the subnet"
    return 0
  fi
  log_warn "airgap: no node on $net could be sealed; the cluster may still reach the internet"
  return 1
}

# airgap_network_nodes <network> - the k3s node containers on a network, one per
# line. The load balancer and the k3d tools container are not nodes.
airgap_network_nodes() {
  local net="${1:?network required}" nodes
  nodes="$(container_cli network inspect "$net" 2>/dev/null | grep -oE '"[Nn]ame": *"k3d-[^"]*-(server|agent)-[0-9]+"' | grep -oE 'k3d-[^"]*' | sort -u)"
  [ -n "$nodes" ] || nodes="$(container_cli ps --filter "network=${net}" --format '{{.Names}}' 2>/dev/null | grep -E -- '-(server|agent)-[0-9]+$')"
  printf '%s\n' "$nodes"
}

# airgap_node_is_sealed <node> - true when the node has no default route.
airgap_node_is_sealed() {
  local node="${1:?node required}" routes
  # The read has to succeed for the answer to mean anything; an unreachable node
  # is not a sealed one. grep is kept off the exit path because "no match" is
  # exactly the success case here.
  routes="$(container_cli exec "$node" ip route 2>/dev/null)" || return 1
  ! printf '%s\n' "$routes" | grep -q '^default'
}

# airgap_pin_hostname <kubeconfig> <ip> <hostname> - make a name resolve inside
# the cluster without asking anything upstream.
#
# Rancher is served at <load-balancer-ip>.sslip.io, and the components that talk
# to it are pods, so they resolve through CoreDNS. Once the nodes have no route
# out, CoreDNS has nothing to forward to, and whether that matters turns out to
# depend on the container runtime:
#
#   - Podman answers from aardvark-dns on the gateway address, which is on-link,
#     and the host performs the upstream lookup. Names kept resolving after
#     sealing, which also meant the sealed cluster could still resolve any name
#     on the internet.
#   - Docker answers from 127.0.0.11 inside the container and forwards through
#     the container's own routing, so sealing takes DNS with it and the Rancher
#     hostname stops resolving.
#
# Neither is what an airgapped site looks like. A real one runs its own DNS and
# answers for its own names, so muster does the same: the hostname is pinned in
# CoreDNS and nothing is asked upstream on either runtime.
#
# k3s imports /etc/coredns/custom/*.server from an optional coredns-custom
# ConfigMap, which is the supported way to add a server block. Editing the
# managed Corefile would work too, and would be undone the next time k3s applied
# its own manifest.
airgap_pin_hostname() {
  local kc="${1:?kubeconfig required}" ip="${2:?ip required}" host="${3:?hostname required}" zone
  command -v kubectl >/dev/null 2>&1 || return 0
  [ -n "$ip" ] || return 0

  # The registrable zone, so the block is authoritative for it: a query for our
  # name is answered and any other name under it is refused rather than escaping.
  zone="$(printf '%s' "$host" | awk -F. 'NF>=2 { print $(NF-1)"."$NF; next } { print }')"

  retry 30 2 "coredns deployment" -- \
    kubectl --kubeconfig "$kc" -n kube-system get deploy coredns

  kubectl --kubeconfig "$kc" apply -f - >/dev/null 2>&1 <<EOF || {
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  muster.server: |
    ${zone}:53 {
        hosts {
            ${ip} ${host}
            fallthrough
        }
    }
EOF
    log_warn "airgap: could not pin $host in CoreDNS; in-cluster lookups of it will fail"
    return 1
  }

  # The reload plugin watches the Corefile, not the files it imports, so a new
  # server block needs the pods restarted to be picked up. Wait for them to be
  # Ready again rather than only for the rollout: the gates that follow resolve
  # names immediately, and a Service with no ready endpoint refuses the query.
  kubectl --kubeconfig "$kc" -n kube-system rollout restart deploy/coredns >/dev/null 2>&1 || true
  kubectl --kubeconfig "$kc" -n kube-system rollout status deploy/coredns --timeout=120s >/dev/null 2>&1 || true
  kubectl --kubeconfig "$kc" -n kube-system wait --for=condition=Ready pod \
    -l k8s-app=kube-dns --timeout=120s >/dev/null 2>&1 || true
  log_info "airgap: $host resolves to $ip from inside the cluster (no upstream DNS)"
}

# airgap_registry_detach <network> - take the registry off a cluster network.
#
# The registry deliberately outlives the cluster, so that a rebuild reuses a
# mirror that cost minutes to fill. Left attached, it also outlives the network:
# k3d refuses to remove a network that still has a container on it, so the
# network survives every teardown and the next run silently reuses it. Detaching
# before the cluster is deleted keeps the mirror and lets the network go.
airgap_registry_detach() {
  local net="${1:?network required}" name
  name="$(airgap_registry_name)"
  container_cli inspect "$name" >/dev/null 2>&1 || return 0
  container_cli network inspect "$net" >/dev/null 2>&1 || return 0
  container_cli network disconnect "$net" "$name" >/dev/null 2>&1 || return 0
  log_info "airgap: registry $name detached from $net"
}

# airgap_network_down <network> - remove the cluster network once the cluster is
# gone. Removal is attempted for any network that is now empty, because the one
# k3d created is as much a leftover as the one muster created; a network that
# still has containers on it (a downstream sharing the management network, or a
# network the caller brought) refuses removal and is left alone.
airgap_network_down() {
  local net="${1:?network required}"
  container_cli network inspect "$net" >/dev/null 2>&1 || return 0
  container_cli network rm "$net" >/dev/null 2>&1 || return 0
  log_info "airgap: removed network $net"
}

# airgap_hosts_toml <registry> [insecure] - a containerd hosts.toml body that
# resolves a registry to the mirror and to the mirror ONLY, on stdout.
#
# The point of interest is what is NOT here: a "server" line. k3s's own
# registries.yaml generation always writes "server = <upstream>", which
# containerd treats as a fallback and tries whenever the mirror answers 404 - so
# an image absent from the mirror is silently pulled from the internet, and a
# mirror gap passes as green. Omitting server makes a missing image fail as a 404
# that names it, which is the whole point of testing against an airgap. The body
# is identical for every upstream registry because they all mirror to the same
# endpoint, including the mirror standing in for itself (systemDefaultRegistry
# makes Rancher ask for images by the mirror's own name).
airgap_hosts_toml() {
  local reg
  reg="$(airgap_registry_host "${1:?registry required}")"
  local insecure="${2:-}" scheme=https
  is_true "$insecure" && scheme=http

  printf '[host."%s://%s/v2"]\n  capabilities = ["pull", "resolve"]\n' "$scheme" "$reg"
  is_true "$insecure" && printf '  skip_verify = true\n'
}

# airgap_write_certs_d <registry> [insecure] - write a containerd certs.d tree
# (one <registry>/hosts.toml per mirrored registry, plus the mirror itself) and
# print the directory. k3d bind-mounts it into the node at the containerd
# registry config_path, which k3s points at certs.d by default.
#
# This replaces handing k3s a registries.yaml: k3s would turn that into the same
# hosts.toml but with the upstream fallback added back, which is exactly what the
# airgap must not have. Writing the files directly keeps the mirror authoritative.
airgap_write_certs_d() {
  local reg="${1:?registry required}" insecure="${2:-}"
  local mirror body dir r
  mirror="$(airgap_registry_host "$reg")"
  dir="${MUSTER_AIRGAP_CERTS_DIR:-${TMPDIR:-/tmp}/muster-certs-${INSTANCE:-e2e}}"
  rm -rf "$dir"
  body="$(airgap_hosts_toml "$reg" "$insecure")"
  for r in $MUSTER_AIRGAP_MIRRORED_REGISTRIES "$mirror"; do
    mkdir -p "$dir/$r"
    printf '%s\n' "$body" >"$dir/$r/hosts.toml"
  done
  printf '%s' "$dir"
}

# airgap_verify_registry <registry> [insecure] - fail early when the mirror is
# not answering, rather than after a cluster has been built around it.
airgap_verify_registry() {
  local reg="${1:?registry required}" insecure="${2:-}" scheme=https
  is_true "$insecure" && scheme=http
  local -a args=(-fsS --max-time 10)
  is_true "$insecure" || args+=(--cacert "$(ca_bundle)")
  curl "${args[@]}" "${scheme}://${reg}/v2/" >/dev/null 2>&1 \
    || die "registry ${reg} is not answering; run 'muster mirror --registry ${reg}' first"
}

# airgap_pull_sources <kubeconfig> - where the running pods' images came from.
# Anything not under the mirror means the mirror was incomplete and the node
# reached the internet to make up the difference, which is exactly what an
# airgapped cluster could not have done.
airgap_pull_sources() {
  local kc="${1:?kubeconfig required}"
  kubectl --kubeconfig "$kc" get pods -A \
    -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
    | sed '/^$/d' | sort -u
}
