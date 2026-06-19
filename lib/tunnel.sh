#!/usr/bin/env bash
# lib/tunnel.sh - cloudflared quick-tunnel lifecycle (external mode).
# Ported in Phase 3 from k3d-rancher.sh (ensure_cloudflared, do_tunnel,
# stop_tunnel). Keep the pinned version + sha256 sums here, the single source.

[ -n "${_MUSTER_TUNNEL_SH:-}" ] && return 0
_MUSTER_TUNNEL_SH=1

# shellcheck disable=SC2034
CLOUDFLARED_VERSION="${CLOUDFLARED_VERSION:-2026.6.0}"
# shellcheck disable=SC2034
CLOUDFLARED_SHA256_linux_amd64="08d27c4c5d3ed73ee3e98ef2ddceb4ad09fd4cfc28e243565a189538e8ccd706"
# shellcheck disable=SC2034
CLOUDFLARED_SHA256_linux_arm64="8482ebf1e74a2a4a1a9f1e090e17e3de08423f94100ece6789287cb26fb9480f"
# shellcheck disable=SC2034
CLOUDFLARED_SHA256_darwin_amd64="2d620f9e7b2ddf5e6f5fe1ed4eee308d8dc4c338bc936bfb18e0022a344daa66"
# shellcheck disable=SC2034
CLOUDFLARED_SHA256_darwin_arm64="1b66920a280235b0180e935c6fb2adcf91fceeeaf66c4365e606bd37d6c587ef"

_muster_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ensure_cloudflared - print a verified cloudflared path, downloading if needed.
ensure_cloudflared() {
  if command -v cloudflared >/dev/null 2>&1; then
    command -v cloudflared
    return 0
  fi

  local arch os want url is_tgz=0
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *)
      log_err "unsupported arch '$(uname -m)' for cloudflared bootstrap"
      return 1
      ;;
  esac

  case "$(uname -s)" in
    Linux)
      os=linux
      want="$(eval echo \"\$CLOUDFLARED_SHA256_linux_${arch}\")"
      url="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${arch}"
      ;;
    Darwin)
      os=darwin
      want="$(eval echo \"\$CLOUDFLARED_SHA256_darwin_${arch}\")"
      url="https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-darwin-${arch}.tgz"
      is_tgz=1
      ;;
    *)
      log_err "unsupported OS '$(uname -s)' for cloudflared bootstrap"
      return 1
      ;;
  esac

  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/muster"
  local bin="${cache_dir}/cloudflared-${CLOUDFLARED_VERSION}-${os}-${arch}"
  mkdir -p "$cache_dir"

  if [ -x "$bin" ] && [ "$(_muster_sha256 "$bin")" = "$want" ]; then
    echo "$bin"
    return 0
  fi

  log_info "cloudflared: downloading pinned ${CLOUDFLARED_VERSION} (${os}-${arch})"
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

  if [ "$is_tgz" -eq 1 ]; then
    local tgz_tmp="${tmp}.tgz"
    mv "$tmp" "$tgz_tmp"
    if ! tar -xzf "$tgz_tmp" -C "$cache_dir" cloudflared; then
      rm -f "$tgz_tmp"
      log_err "cloudflared extract failed"
      return 1
    fi
    rm -f "$tgz_tmp"
    mv "${cache_dir}/cloudflared" "$tmp"
  fi

  local got
  got="$(_muster_sha256 "$tmp")"
  if [ "$got" != "$want" ]; then
    rm -f "$tmp"
    log_err "cloudflared checksum mismatch (${os}-${arch})"
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

  # macOS lacks setsid and its networking stack often drops QUIC (UDP) tunnels,
  # causing Error 1033. Force http2 (TCP) on Darwin and use 127.0.0.1 to avoid
  # IPv6 resolution of localhost.
  local cf_args=(tunnel --url "https://127.0.0.1:${port}" --no-tls-verify)
  if [ "$(uname -s)" = "Darwin" ]; then
    cf_args+=(--protocol http2)
  fi

  if command -v setsid >/dev/null 2>&1; then
    setsid "$cf" "${cf_args[@]}" >>"$log" 2>&1 </dev/null &
  else
    nohup "$cf" "${cf_args[@]}" >>"$log" 2>&1 </dev/null &
    disown
  fi
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

# tunnel_url - retrieve the current tunnel url from the instance log.
tunnel_url() {
  local log="/tmp/muster-tunnel-${INSTANCE}.log"
  if [ -f "$log" ]; then
    grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$log" | head -1 || true
  fi
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
