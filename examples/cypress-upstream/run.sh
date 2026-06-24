#!/usr/bin/env bash
# Run the upstream rancher/dashboard Cypress suite against a muster-provisioned
# Rancher on k3d. Provisions if not already up.
#
# Usage:
#   DASHBOARD_SRC=~/repos/dashboard GREP_TAGS='@navigation' ./run.sh
#   EXTERNAL=true DASHBOARD_SRC=~/repos/dashboard GREP_TAGS='@provisioning' ./run.sh
#
# Environment:
#   DASHBOARD_SRC  (required) Path to a rancher/dashboard checkout. Run
#                  one-shot.sh or `muster build-ui` first so dist exists.
#                  Test dependencies install into a named docker volume.
#   GREP_TAGS      Cypress grep tag filter (e.g. @navigation, @generic).
#   EXTERNAL       Set to true for cloudflared tunnel (provisioning tests).
#   FRESH          Set to true to tear down and reprovision first, so a freshly
#                  built dist is mounted (a reused cluster keeps its old dist).
#   CYPRESS_BROWSER Browser for the runner. Default: chrome on Linux (GitHub
#                  Actions parity), chromium on macOS local Docker Desktop.
#   PROVIDER       muster provider (default: k3d).
#   INSTANCE       muster instance name (default: e2e).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MUSTER="$MUSTER_ROOT/muster"

: "${DASHBOARD_SRC:?set DASHBOARD_SRC to your rancher/dashboard checkout}"
: "${PROVIDER:=k3d}"
: "${INSTANCE:=e2e}"

default_cypress_browser() {
  case "$(uname -s)" in
    Darwin) echo chromium ;;
    Linux) echo chrome ;;
    *) echo auto ;;
  esac
}

if [ -z "${CYPRESS_BROWSER:-}" ]; then
  CYPRESS_BROWSER="$(default_cypress_browser)"
fi

export DASHBOARD_SRC PROVIDER INSTANCE CYPRESS_BROWSER

is_truthy() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# A reused cluster keeps whatever dist it was provisioned with, so a freshly
# built dist is ignored until it is reprovisioned. Set FRESH=true to tear the
# instance down first and provision again.
if is_truthy "${FRESH:-}"; then
  echo "--- FRESH: tearing down existing $PROVIDER/$INSTANCE ---"
  "$MUSTER" down --provider "$PROVIDER" --instance "$INSTANCE" >/dev/null 2>&1 || true
fi

# Provision if not already up.
if ! "$MUSTER" env --provider "$PROVIDER" --instance "$INSTANCE" --out cypress >/dev/null 2>&1; then
  echo "--- Provisioning Rancher ($PROVIDER/$INSTANCE) ---"
  up_args=(--provider "$PROVIDER" --instance "$INSTANCE"
    --dashboard-dist "$DASHBOARD_SRC/dist" --out cypress)
  is_truthy "${EXTERNAL:-}" && up_args+=(--external)
  "$MUSTER" up "${up_args[@]}"
else
  echo "--- Reusing existing $PROVIDER/$INSTANCE (dist not rebuilt; set FRESH=true to reprovision) ---"
fi

# Source the handoff.
eval "$("$MUSTER" env --provider "$PROVIDER" --instance "$INSTANCE" --out cypress)"
export TEST_BASE_URL API TEST_USERNAME CATTLE_BOOTSTRAP_PASSWORD TEST_PASSWORD
export HOST_UID="${HOST_UID:-$(id -u)}"
export HOST_GID="${HOST_GID:-$(id -g)}"

echo "--- Running Cypress setup (first-login) ---"
echo "    TEST_BASE_URL=$TEST_BASE_URL"
echo "    CYPRESS_BROWSER=$CYPRESS_BROWSER"
docker compose -f "$SCRIPT_DIR/docker-compose.yml" run --rm cypress-setup

echo "--- Running Cypress (GREP_TAGS=${GREP_TAGS:-<all>}) ---"
docker compose -f "$SCRIPT_DIR/docker-compose.yml" run --rm cypress cypress-run "$@"
