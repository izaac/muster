#!/usr/bin/env bash
# lib/external.sh - external-access patches: server-url pin and
# agent-tls-mode=system-store. Ported in Phase 3 from k3d-rancher.sh do_wait.

[ -n "${_MUSTER_EXTERNAL_SH:-}" ] && return 0
_MUSTER_EXTERNAL_SH=1

# external_apply - point server-url at the public host and set system-store TLS
# BEFORE any downstream cluster registers.
external_apply() { die "external_apply: not implemented (Phase 3)"; }
