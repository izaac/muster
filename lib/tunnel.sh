#!/usr/bin/env bash
# lib/tunnel.sh - cloudflared quick-tunnel lifecycle (external mode).
# Ported in Phase 3 from k3d-rancher.sh (ensure_cloudflared, do_tunnel,
# stop_tunnel). Keep the pinned version + sha256 sums here, the single source.

[ -n "${_MUSTER_TUNNEL_SH:-}" ] && return 0
_MUSTER_TUNNEL_SH=1

# ensure_cloudflared - print a verified cloudflared path, downloading if needed.
ensure_cloudflared() { die "ensure_cloudflared: not implemented (Phase 3)"; }

# tunnel_up - start a quick tunnel to the local Rancher; print the public URL.
tunnel_up() { die "tunnel_up: not implemented (Phase 3)"; }

# tunnel_down - stop the tunnel recorded for this instance.
tunnel_down() { die "tunnel_down: not implemented (Phase 3)"; }
