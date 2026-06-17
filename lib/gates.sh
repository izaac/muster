#!/usr/bin/env bash
# lib/gates.sh - readiness gates (webhook, CAPI, authProviders, settle).
# Ported in Phase 1 from k3d-rancher.sh do_wait.

[ -n "${_MUSTER_GATES_SH:-}" ] && return 0
_MUSTER_GATES_SH=1

# gates_wait - block until Rancher is serving and its controllers are ready.
gates_wait() { die "gates_wait: not implemented (Phase 1)"; }
