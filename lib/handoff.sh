#!/usr/bin/env bash
# lib/handoff.sh - emit consumer handoff in the requested format.
# Implemented in Phase 2.

[ -n "${_MUSTER_HANDOFF_SH:-}" ] && return 0
_MUSTER_HANDOFF_SH=1

# handoff_write <env|cypress|json> - write/print the handoff for a consumer.
handoff_write() { die "handoff_write: not implemented (Phase 2)"; }
