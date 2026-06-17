#!/usr/bin/env bash
# lib/tunnel.sh - cloudflared quick-tunnel lifecycle (external mode).
# Ported in Phase 3 from k3d-rancher.sh (ensure_cloudflared, do_tunnel,
# stop_tunnel). Keep the pinned version + sha256 sums here, the single source.

[ -n "${_MUSTER_TUNNEL_SH:-}" ] && return 0
_MUSTER_TUNNEL_SH=1

CLOUDFLARED_VERSION="${CLOUDFLARED_VERSION:-2026.6.0}"
CLOUDFLARED_SHA256_amd64="08d27c4c5d3ed73ee3e98ef2ddceb4ad09fd4cfc28e243565a189538e8ccd706"
CLOUDFLARED_SHA256_arm64="8482ebf1e74a2a4a1a9f1e090e17e3de08423f94100ece6789287cb26fb9480f"

# ensure_cloudflared - print a verified cloudflared path, downloading if needed.
ensure_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    command -v cloudflared
    return 0
  fi

  local arch want
  case "$(uname -m)" in
    x86_64)
      arch=amd64
      want="$CLOUDFLARED_SHA256_amd64"
      ;;
    aarch64 | arm64)
      arch=arm64
      want="$CLOUDFLARED_SHA256_arm64"
      ;;
    *)
      log_err "unsupported arch '$(uname -m)' for cloudflared bootstrap"
      return 1
      ;;
  esac

  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/muster"
  local bin="${cache_dir}/cloudflared-${CLOUDFLARED_VERSION}-${arch}"
  mkdir -p "$cache_dir"

  if [ -x "$bin" ] && [ "$(sha256sum "$bin" | awk '{print $1}')" = "$want" ]; then
    echo "$bin"
    return 0
  fi

  local url="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${arch}"
  log_info "cloudflared: downloading pinned ${CLOUDFLARED_VERSION} (${arch})"
  local tmp="${bin}.tmp.$$"
  local curl_args=(-fsSL -o "$tmp")
  local ca
  ca="$(ca_bundle)"
  [ -n "$ca" ] && curl_args+=(--cacert "$ca")
  if ! curl "${curl_args[@]}" "$url"; then
    rm -f "$tmp"
    log_err "cloudflared download failed: $url"
    return 1
  fi

  local got
  got="$(sha256sum "$tmp" | awk '{print $1}')"
  if [ "$got" != "$want" ]; then
    rm -f "$tmp"
    log_err "cloudflared checksum mismatch (${arch})"
    log_err "  expected: $want"
    log_err "  got:      $got"
    return 1
  fi

  chmod +x "$tmp"
  mv -f "$tmp" "$bin"
  log_info "cloudflared: verified and cached at $bin"
  echo "$bin"
}

# tunnel_up - start a quick tunnel to the local Rancher; print the public URL.
tunnel_up() {
  local port
  if declare -F driver_tunnel_port >/dev/null; then
    port="$(driver_tunnel_port)"
  else
    die "tunnel_up requires driver_tunnel_port in the substrate driver"
  fi

  local cf url log pidfile
  cf="$(ensure_cloudflared)"
  log="/tmp/muster-tunnel-${INSTANCE}.log"
  pidfile="/tmp/muster-tunnel-${INSTANCE}.pid"
  : >"$log"

  setsid "$cf" tunnel --url "https://localhost:${port}" --no-tls-verify \
    >>"$log" 2>&1 &
  echo "$!" >"$pidfile"

  local i
  for ((i = 1; i <= 30; i++)); do
    url="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$log" | head -1 || true)"
    [ -n "$url" ] && break
    sleep 1
  done
  if [ -z "$url" ]; then
    log_err "cloudflared did not report a tunnel url (see $log)"
    return 1
  fi
  echo "$url"
}

# tunnel_down - stop the tunnel recorded for this instance.
tunnel_down() {
  local port
  if declare -F driver_tunnel_port >/dev/null; then
    port="$(driver_tunnel_port)"
  else
    return 0
  fi

  local pidfile="/tmp/muster-tunnel-${INSTANCE}.pid" p
  if [ -f "$pidfile" ]; then
    kill "$(cat "$pidfile")" 2>/dev/null || true
    rm -f "$pidfile" "/tmp/muster-tunnel-${INSTANCE}.log"
  fi
  for p in $(pgrep -f "cloudflared.*localhost:${port}" 2>/dev/null || true); do
    kill "$p" 2>/dev/null || true
  done
}
