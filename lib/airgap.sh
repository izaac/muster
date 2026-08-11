#!/usr/bin/env bash
# lib/airgap.sh - point a cluster at a private registry instead of the internet.
#
# A real airgap is a network fact rather than a setting, and reproducing one
# locally would mean a docker network with no route out. What matters for
# testing the install is narrower: every image must come from the mirror. That
# is a containerd concern, so it is expressed the way containerd expresses it,
# with a registries.yaml that mirrors the upstream registries onto ours.
#
# Mirroring at the container runtime rather than through systemDefaultRegistry
# is deliberate. systemDefaultRegistry rewrites the names Rancher asks for, so a
# missing image looks like a Rancher misconfiguration; a runtime mirror leaves
# the names alone, so anything absent from the mirror fails as a plain pull
# error naming the image we forgot. That is the failure we want while we are
# still establishing what a complete mirror contains.

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
airgap_registry_name() { printf '%s-%s' "$MUSTER_REGISTRY_NAME_PREFIX" "${INSTANCE:-e2e}"; }

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

# airgap_registries_yaml <registry> [insecure] - a containerd registry config
# mirroring the upstream registries onto the given one, on stdout.
airgap_registries_yaml() {
  local reg
  reg="$(airgap_registry_host "${1:?registry required}")"
  local insecure="${2:-}" r

  local scheme=https
  is_true "$insecure" && scheme=http

  # The mirror stands in for the upstream registries, and also for itself:
  # systemDefaultRegistry makes Rancher ask for images by the mirror's own name,
  # and such a request is not covered by a rule for some other registry. Without
  # an entry of its own containerd would default to HTTPS and fail against a
  # plain registry with "server gave HTTP response to HTTPS client".
  printf 'mirrors:\n'
  for r in $MUSTER_AIRGAP_MIRRORED_REGISTRIES "$reg"; do
    printf '  "%s":\n    endpoint:\n      - "%s://%s"\n' "$r" "$scheme" "$reg"
  done

  if is_true "$insecure"; then
    printf 'configs:\n  "%s":\n    tls:\n      insecure_skip_verify: true\n' "$reg"
  fi
}

# airgap_write_registries <registry> [insecure] - write the config and print its
# path. k3d reads it at cluster creation and installs it on every node.
airgap_write_registries() {
  local reg="${1:?registry required}" insecure="${2:-}" path
  path="${MUSTER_AIRGAP_REGISTRIES_FILE:-${TMPDIR:-/tmp}/muster-registries-${INSTANCE:-e2e}.yaml}"
  airgap_registries_yaml "$reg" "$insecure" >"$path"
  printf '%s' "$path"
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
