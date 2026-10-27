#!/usr/bin/env bats
# Unit tests for the external-access patches in lib/external.sh.
#
# kubectl and retry are stubbed, so these assert the settings that must be
# written and the order they are written in, without a cluster.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  . "$ROOT/lib/util.sh"
  # shellcheck source=../lib/external.sh
  . "$ROOT/lib/external.sh"

  PATCHES="$BATS_TEST_TMPDIR/patches"
  : >"$PATCHES"

  # Execute the command the retry wraps, once, without sleeping.
  retry() {
    shift 3
    [ "${1:-}" = "--" ] && shift
    "$@"
  }
  kubectl() { printf '%s\n' "$*" >>"$PATCHES"; }
}

@test "external_apply pins server-url, system-store TLS and clears cacerts" {
  external_apply /tmp/kc rancher.example.com >/dev/null
  grep -q 'patch settings.management.cattle.io server-url --type=merge -p {"value":"https://rancher.example.com"}' "$PATCHES"
  grep -q 'patch settings.management.cattle.io agent-tls-mode --type=merge -p {"value":"system-store"}' "$PATCHES"
  # The self-signed tls-rancher-ingress CA would otherwise be baked into every
  # downstream agent manifest as --ca-checksum, where Cloudflare's edge cert can
  # never validate it.
  grep -q 'patch settings.management.cattle.io cacerts --type=merge -p {"value":""}' "$PATCHES"
}

@test "external_apply clears cacerts after the TLS mode is set" {
  external_apply /tmp/kc rancher.example.com >/dev/null
  local tls cacerts
  tls="$(grep -n 'agent-tls-mode' "$PATCHES" | cut -d: -f1)"
  cacerts="$(grep -n 'cacerts' "$PATCHES" | cut -d: -f1)"
  [ -n "$tls" ] && [ -n "$cacerts" ]
  [ "$cacerts" -gt "$tls" ]
}

@test "external_apply announces the cacerts clear" {
  run external_apply /tmp/kc rancher.example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"clearing cacerts (Cloudflare edge cert)"* ]]
}
