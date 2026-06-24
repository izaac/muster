#!/usr/bin/env bash
# drivers/existing.sh - install Rancher onto a caller-supplied cluster.
#
# The "existing" substrate owns no cluster of its own: the caller points muster
# at an already-running Kubernetes cluster via KUBECONFIG and names the
# hostname Rancher is served at via RANCHER_HOST. driver_up/driver_down are
# no-ops for the cluster lifecycle (muster never creates or deletes a cluster
# it does not own); the core still runs its helm install, readiness gates, and
# handoff against the supplied cluster. Covers the ansible job_type=existing
# path.
#
# Driver contract (4 verbs):
#   driver_up         validate inputs + reachability; no cluster is created.
#   driver_down       no-op: muster never deletes a cluster it did not create.
#   driver_kubeconfig print the caller-supplied KUBECONFIG path.
#   driver_endpoint   print the caller-supplied RANCHER_HOST.
#
# driver_installs_rancher is deliberately NOT declared, so the core runs
# helm_install_rancher onto the cluster exactly like k3d. Inputs:
#   KUBECONFIG    path to a kubeconfig for the target cluster (--kubeconfig).
#   RANCHER_HOST  hostname Rancher is reachable at; drives the ingress hostname
#                 and the gate/handoff URLs (--rancher-host).
#
# External mode is unsupported: RANCHER_HOST is already a real, reachable
# name, so there is nothing for a quick tunnel to expose.

[ -n "${_MUSTER_DRIVER_EXISTING_SH:-}" ] && return 0
_MUSTER_DRIVER_EXISTING_SH=1

# existing_kubeconfig - the caller-supplied kubeconfig path, validated readable.
existing_kubeconfig() {
  local kc="${KUBECONFIG:-}"
  [ -n "$kc" ] || die "existing provider needs --kubeconfig <path> (or KUBECONFIG)"
  [ -r "$kc" ] || die "kubeconfig not readable: $kc"
  printf '%s' "$kc"
}

# existing_host - the caller-supplied Rancher hostname, validated non-empty.
existing_host() {
  [ -n "${RANCHER_HOST:-}" ] || die "existing provider needs --rancher-host <hostname> (or RANCHER_HOST)"
  printf '%s' "$RANCHER_HOST"
}

# driver_up - the cluster already exists; validate inputs and reachability so a
# misconfiguration fails fast instead of midway through the helm install. The
# checks are inline (not via the echo helpers) so a die propagates out of
# driver_up rather than being swallowed by a command substitution.
driver_up() {
  if is_true "${EXTERNAL:-}"; then
    die "existing provider does not support --external (RANCHER_HOST is already reachable)"
  fi
  require_cmd kubectl "install kubectl to talk to the existing cluster"
  [ -n "${KUBECONFIG:-}" ] || die "existing provider needs --kubeconfig <path> (or KUBECONFIG)"
  [ -r "$KUBECONFIG" ] || die "kubeconfig not readable: $KUBECONFIG"
  [ -n "${RANCHER_HOST:-}" ] || die "existing provider needs --rancher-host <hostname> (or RANCHER_HOST)"
  kubectl --kubeconfig "$KUBECONFIG" cluster-info >/dev/null 2>&1 \
    || die "cannot reach the cluster with kubeconfig: $KUBECONFIG"
  log_info "existing: using cluster '$KUBECONFIG', serving rancher at '$RANCHER_HOST'"
}

# driver_down - muster did not create the cluster, so it does not delete it.
# Re-running up is idempotent (helm upgrade --install), so leaving the cluster
# in place is the least-surprising behaviour for a caller-owned substrate.
driver_down() {
  log_info "existing: leaving the caller-owned cluster untouched (no teardown)"
}

driver_kubeconfig() { existing_kubeconfig; }

driver_endpoint() { existing_host; }
