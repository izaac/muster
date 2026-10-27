#!/usr/bin/env bats
# Unit tests for the cloudflared quick-tunnel lifecycle in lib/tunnel.sh.
#
# The tunnel is exercised with a fake cloudflared, so nothing here touches the
# network or a real cloudflared process: tunnel_up is about what the wrapper
# waits for and which flags it passes, and tunnel_down is about which processes
# it looks for.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  . "$ROOT/lib/util.sh"
  # shellcheck source=../lib/tunnel.sh
  . "$ROOT/lib/tunnel.sh"

  INSTANCE="test-tunnel-$$"
  ARGS_FILE="$BATS_TEST_TMPDIR/args"
  MARK="$BATS_TEST_TMPDIR/mark"
  # The fake cloudflared is a child process, so it needs these in its environment.
  export ARGS_FILE MARK

  # Never signal a real process from a test; record what would have been killed.
  kill() { printf 'kill %s\n' "$1" >>"$MARK"; }
  pgrep() { return 1; }
  driver_tunnel_port() { printf '8443'; }

  # bats passes the test name to setup, so name the kind explicitly.
  _mock_cloudflared registered
}

# _mock_cloudflared [registration] - write a fake cloudflared that records its
# arguments and prints a tunnel URL, optionally with the registration line.
_mock_cloudflared() {
  CF="$BATS_TEST_TMPDIR/cloudflared-mock"
  cat >"$CF" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$ARGS_FILE"
printf '%s\n' 'INF |  https://fake-tunnel.trycloudflare.com  |'
MOCK
  if [ "${1:-registered}" = registered ]; then
    printf '%s\n' "printf '%s\\n' 'INF Registered tunnel connection connIndex=0'" >>"$CF"
  fi
  chmod +x "$CF"
  ensure_cloudflared() { printf '%s' "$CF"; }
}

teardown() {
  rm -f "/tmp/muster-tunnel-${INSTANCE}.log" "/tmp/muster-tunnel-${INSTANCE}.pid"
}

# --- tunnel_up ---------------------------------------------------------------

@test "tunnel_up forces http2 so QUIC cannot break the tunnel" {
  run tunnel_up
  [ "$status" -eq 0 ]
  [ "$output" = "https://fake-tunnel.trycloudflare.com" ]
  [ -f "$ARGS_FILE" ]
  grep -q -- '--protocol http2' "$ARGS_FILE"
  # Loopback spelled as an address, not a name that may resolve to IPv6.
  grep -q -- '--url https://127.0.0.1:8443' "$ARGS_FILE"
  grep -q -- '--no-tls-verify' "$ARGS_FILE"
}

@test "tunnel_up waits for the registration line, not just the URL" {
  # A run that reports the URL and never registers must fail: returning early
  # installs Rancher while the edge handshake is still pending.
  _mock_cloudflared unregistered
  MUSTER_TUNNEL_TIMEOUT=2 run tunnel_up
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not register within 2s"* ]]
}

@test "a timed-out tunnel is killed, drops its pidfile, and keeps its log" {
  _mock_cloudflared unregistered
  local log="/tmp/muster-tunnel-${INSTANCE}.log" pidfile="/tmp/muster-tunnel-${INSTANCE}.pid"
  MUSTER_TUNNEL_TIMEOUT=2 run tunnel_up
  [ "$status" -ne 0 ]
  # The message points at the log, so the log has to survive the cleanup.
  [ -f "$log" ]
  grep -q 'trycloudflare.com' "$log"
  [ ! -f "$pidfile" ]
  grep -q '^kill ' "$MARK"
}

@test "tunnel_up reports a timeout when cloudflared says nothing at all" {
  CF="$BATS_TEST_TMPDIR/silent"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$CF"
  chmod +x "$CF"
  ensure_cloudflared() { printf '%s' "$CF"; }
  MUSTER_TUNNEL_TIMEOUT=2 run tunnel_up
  [ "$status" -ne 0 ]
  [[ "$output" == *"did not register within 2s"* ]]
}

@test "tunnel_up honours MUSTER_TUNNEL_TIMEOUT" {
  _mock_cloudflared unregistered
  MUSTER_TUNNEL_TIMEOUT=1 run tunnel_up
  [ "$status" -ne 0 ]
  [[ "$output" == *"within 1s"* ]]
}

# --- tunnel_down -------------------------------------------------------------

@test "tunnel_down matches both loopback spellings of the tunnel target" {
  PATTERN_FILE="$BATS_TEST_TMPDIR/pattern"
  pgrep() { printf '%s\n' "$*" >"$PATTERN_FILE"; }
  tunnel_down
  [ -f "$PATTERN_FILE" ]
  grep -q 'cloudflared' "$PATTERN_FILE"
  grep -q '127\\.0\\.0\\.1|localhost' "$PATTERN_FILE"
  grep -q ':8443' "$PATTERN_FILE"
}

@test "tunnel_down is a no-op without a driver tunnel port" {
  unset -f driver_tunnel_port
  run tunnel_down
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
