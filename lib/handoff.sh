#!/usr/bin/env bash
# lib/handoff.sh - emit consumer handoff in the requested format.
#
# Three adapters over the same live cluster facts exported by cmd_up:
#   env      shell key=value lines for `source`/`eval` (muster's own schema).
#   cypress  the env vars upstream rancher/dashboard cypress/base-config.ts
#            reads (TEST_BASE_URL, TEST_USERNAME, CATTLE_BOOTSTRAP_PASSWORD,
#            TEST_PASSWORD, API), so the upstream Cypress suite runs unchanged.
#   json     a single JSON object for programmatic consumers.

[ -n "${_MUSTER_HANDOFF_SH:-}" ] && return 0
_MUSTER_HANDOFF_SH=1

# _json_str <value> - escape a value for embedding in a JSON string literal.
_json_str() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# handoff_write <env|cypress|json> - write/print the handoff for a consumer.
# Reads the live cluster facts exported by cmd_up:
#   MUSTER_HOSTNAME MUSTER_KUBECONFIG MUSTER_PASSWORD MUSTER_USERNAME
handoff_write() {
  local fmt="${1:-env}"
  local host="${MUSTER_HOSTNAME:?cmd_up must run first}"
  local kc="${MUSTER_KUBECONFIG:-}"
  local pass="${MUSTER_PASSWORD:-password1234}"
  local user="${MUSTER_USERNAME:-admin}"
  local base="https://${host}/dashboard"
  local api="https://${host}"

  case "$fmt" in
    env)
      printf 'TEST_BASE_URL=%s\n' "$base"
      printf 'RANCHER_HOSTNAME=%s\n' "$host"
      printf 'KUBECONFIG=%s\n' "$kc"
      printf 'TEST_PASSWORD=%s\n' "$pass"
      ;;
    cypress)
      # On a fresh Rancher the bootstrap password is the initial admin
      # password; base-config prefers CATTLE_BOOTSTRAP_PASSWORD and runs the
      # setup spec with it. TEST_PASSWORD is emitted to the same value so login
      # works whether or not the setup spec is skipped.
      printf 'TEST_BASE_URL=%s\n' "$base"
      printf 'TEST_USERNAME=%s\n' "$user"
      printf 'CATTLE_BOOTSTRAP_PASSWORD=%s\n' "$pass"
      printf 'TEST_PASSWORD=%s\n' "$pass"
      printf 'API=%s\n' "$api"
      ;;
    json)
      printf '{\n'
      printf '  "baseUrl": "%s",\n' "$(_json_str "$base")"
      printf '  "hostname": "%s",\n' "$(_json_str "$host")"
      printf '  "api": "%s",\n' "$(_json_str "$api")"
      printf '  "kubeconfig": "%s",\n' "$(_json_str "$kc")"
      printf '  "username": "%s",\n' "$(_json_str "$user")"
      printf '  "password": "%s",\n' "$(_json_str "$pass")"
      printf '  "bootstrapPassword": "%s"\n' "$(_json_str "$pass")"
      printf '}\n'
      ;;
    *)
      die "handoff_write: unknown format '$fmt' (env|cypress|json)"
      ;;
  esac
}
