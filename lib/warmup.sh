#!/usr/bin/env bash
# lib/warmup.sh - provisioning-controller warm-up to avoid the cold-start flake.
# Ported in Phase 3 from k3d-rancher.sh warm_provisioning.

[ -n "${_MUSTER_WARMUP_SH:-}" ] && return 0
_MUSTER_WARMUP_SH=1

# warmup_provisioning - create one throwaway imported cluster (spec:{}, zero
# machines) so the controller warms its informer caches, then delete it.
warmup_provisioning() { die "warmup_provisioning: not implemented (Phase 3)"; }
