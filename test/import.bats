#!/usr/bin/env bats
# Unit tests for the server-url handoff in lib/import.sh.
#
# An external management Rancher is pinned to its tunnel hostname. import runs in
# its own process, so it has to read the setting and leave an external hostname
# alone instead of rewriting it back to the internal .sslip.io endpoint that
# outside agents cannot reach.
#
# kubectl, retry and tunnel_url are stubbed; no cluster is touched.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  . "$ROOT/lib/util.sh"
  # shellcheck source=../lib/import.sh
  . "$ROOT/lib/import.sh"

  CUR_URL=""
  PATCHES="$BATS_TEST_TMPDIR/patches"
  : >"$PATCHES"
  MGMT_HOST="e2e-abc.sslip.io"

  kubectl() {
    case "$*" in
      *" get settings.management.cattle.io server-url"*) printf '%s' "$CUR_URL" ;;
      *) printf '%s\n' "$*" >>"$PATCHES" ;;
    esac
  }
  retry() {
    shift 3
    [ "${1:-}" = "--" ] && shift
    "$@"
  }
  tunnel_url() { printf '%s' "${TUNNEL:-}"; }
}

# --- import_keep_server_url (pure) -------------------------------------------

@test "a server-url that names the live tunnel is kept" {
  import_keep_server_url "https://abc.trycloudflare.com" "https://abc.trycloudflare.com" "$MGMT_HOST"
}

@test "a quick-tunnel hostname is kept even when no tunnel is running here" {
  import_keep_server_url "https://abc.trycloudflare.com" "" "$MGMT_HOST"
}

@test "in external mode a non-endpoint server-url is kept" {
  EXTERNAL=true import_keep_server_url "https://rancher.example.com" "" "$MGMT_HOST"
}

@test "the internal endpoint is rewritten even in external mode" {
  EXTERNAL=true run import_keep_server_url "https://${MGMT_HOST}" "" "$MGMT_HOST"
  [ "$status" -ne 0 ]
}

@test "without external mode or a tunnel the endpoint is rewritten" {
  EXTERNAL=false run import_keep_server_url "https://rancher.example.com" "" "$MGMT_HOST"
  [ "$status" -ne 0 ]
  run import_keep_server_url "https://${MGMT_HOST}" "" "$MGMT_HOST"
  [ "$status" -ne 0 ]
  run import_keep_server_url "" "" "$MGMT_HOST"
  [ "$status" -ne 0 ]
}

# --- import_sync_server_url (the import_run handoff) --------------------------

@test "import keeps an external server-url instead of patching it back" {
  CUR_URL="https://abc.trycloudflare.com"
  EXTERNAL=true run import_sync_server_url /tmp/kc "$MGMT_HOST"
  [ "$status" -eq 0 ]
  [[ "$output" == *"import: keeping external server-url https://abc.trycloudflare.com"* ]]
  [ ! -s "$PATCHES" ]
}

@test "import keeps the server-url when the matching tunnel is still running" {
  CUR_URL="https://abc.trycloudflare.com"
  TUNNEL="https://abc.trycloudflare.com"
  import_sync_server_url /tmp/kc "$MGMT_HOST" >/dev/null
  [ ! -s "$PATCHES" ]
}

@test "import points server-url at the management host when nothing is external" {
  CUR_URL="https://${MGMT_HOST}"
  import_sync_server_url /tmp/kc "$MGMT_HOST" >/dev/null
  grep -q "patch settings.management.cattle.io server-url --type=merge -p {\"value\":\"https://${MGMT_HOST}\"}" "$PATCHES"
}

@test "import sets the management host when server-url is empty" {
  CUR_URL=""
  import_sync_server_url /tmp/kc "$MGMT_HOST" >/dev/null
  grep -q '"value":"https://e2e-abc.sslip.io"' "$PATCHES"
}

@test "an unreadable server-url falls back to setting the management host" {
  kubectl() {
    case "$*" in
      *" get "*) return 1 ;;
      *) printf '%s\n' "$*" >>"$PATCHES" ;;
    esac
  }
  import_sync_server_url /tmp/kc "$MGMT_HOST" >/dev/null
  grep -q "patch settings.management.cattle.io server-url --type=merge" "$PATCHES"
}
