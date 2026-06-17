#!/usr/bin/env bash
# drivers/k3d.sh - k3d substrate driver.
#
# Driver contract (every driver defines exactly these four verbs):
#   driver_up         create/ensure the cluster; leave KUBECONFIG resolvable.
#   driver_down       destroy the cluster and sweep substrate state.
#   driver_kubeconfig print an absolute kubeconfig path on stdout.
#   driver_endpoint   print the in-cluster Rancher hostname (e.g. <ip>.sslip.io).
#
# Ported in Phase 1 from k3d-rancher.sh (cluster create/delete, lb_ip, sslip).

[ -n "${_MUSTER_DRIVER_K3D_SH:-}" ] && return 0
_MUSTER_DRIVER_K3D_SH=1

driver_up() { die "k3d driver_up: not implemented (Phase 1)"; }
driver_down() { die "k3d driver_down: not implemented (Phase 1)"; }
driver_kubeconfig() { die "k3d driver_kubeconfig: not implemented (Phase 1)"; }
driver_endpoint() { die "k3d driver_endpoint: not implemented (Phase 1)"; }
