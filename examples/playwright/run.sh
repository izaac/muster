#!/usr/bin/env bash
# Run the izaac/dashboard-e2e-pw Playwright suite against a muster-provisioned
# Rancher on k3d. Provisions if not already up.
#
# Usage:
#   PW_REPO_PATH=~/repos/dashboard-e2e-pw GREP_TAGS='@navigation' ./run.sh
#   EXTERNAL=true PW_REPO_PATH=~/repos/dashboard-e2e-pw GREP_TAGS='@provisioning' ./run.sh
#
# Environment:
#   PW_REPO_PATH    (required) Path to dashboard-e2e-pw checkout.
#   DASHBOARD_SRC   Path to rancher/dashboard checkout (for dist mount).
#   GREP_TAGS       Playwright grep tag filter (e.g. @navigation, @generic).
#   EXTERNAL        Set to true for cloudflared tunnel (provisioning tests).
#   FRESH           Set to true to tear down and reprovision first, so a freshly
#                   built dist is mounted (a reused cluster keeps its old dist).
#   PROVIDER        muster provider (default: k3d).
#   INSTANCE        muster instance name (default: e2e).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MUSTER="$MUSTER_ROOT/muster"

: "${PW_REPO_PATH:?set PW_REPO_PATH to your dashboard-e2e-pw checkout}"
: "${PROVIDER:=k3d}"
: "${INSTANCE:=e2e}"

export PW_REPO_PATH PROVIDER INSTANCE

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
  up_args=(--provider "$PROVIDER" --instance "$INSTANCE" --out cypress)
  [ -n "${DASHBOARD_SRC:-}" ] && up_args+=(--dashboard-dist "$DASHBOARD_SRC/dist")
  is_truthy "${EXTERNAL:-}" && up_args+=(--external)
  "$MUSTER" up "${up_args[@]}"
else
  echo "--- Reusing existing $PROVIDER/$INSTANCE (dist not rebuilt; set FRESH=true to reprovision) ---"
fi

# Source the handoff.
eval "$("$MUSTER" env --provider "$PROVIDER" --instance "$INSTANCE" --out cypress)"
export TEST_BASE_URL CATTLE_BOOTSTRAP_PASSWORD TEST_PASSWORD TEST_USERNAME
export HOST_UID="${HOST_UID:-$(id -u)}"
export HOST_GID="${HOST_GID:-$(id -g)}"

echo "--- Running Playwright (GREP_TAGS=${GREP_TAGS:-<all>}) ---"
echo "    TEST_BASE_URL=$TEST_BASE_URL"

# Ensure output dirs exist with correct ownership.
mkdir -p "$PW_REPO_PATH/test-results" "$PW_REPO_PATH/playwright-report"

docker compose -f "$SCRIPT_DIR/docker-compose.yml" run --rm tests playwright-run "$@"
