#!/usr/bin/env bash
# Run the upstream rancher/dashboard Cypress suite against a muster-provisioned
# Rancher on k3d. Provisions if not already up.
#
# Usage:
#   DASHBOARD_SRC=~/repos/dashboard GREP_TAGS='@navigation' ./run.sh
#   EXTERNAL=true DASHBOARD_SRC=~/repos/dashboard GREP_TAGS='@provisioning' ./run.sh
#
# Environment:
#   DASHBOARD_SRC  (required) Path to a rancher/dashboard checkout with
#                  node_modules installed (yarn install).
#   GREP_TAGS      Cypress grep tag filter (e.g. @navigation, @generic).
#   EXTERNAL       Set to true for cloudflared tunnel (provisioning tests).
#   PROVIDER       muster provider (default: k3d).
#   INSTANCE       muster instance name (default: e2e).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MUSTER="$MUSTER_ROOT/muster"

: "${DASHBOARD_SRC:?set DASHBOARD_SRC to your rancher/dashboard checkout}"
: "${PROVIDER:=k3d}"
: "${INSTANCE:=e2e}"

export DASHBOARD_SRC PROVIDER INSTANCE

# Provision if not already up.
if ! "$MUSTER" env --provider "$PROVIDER" --instance "$INSTANCE" --out cypress >/dev/null 2>&1; then
  echo "--- Provisioning Rancher ($PROVIDER/$INSTANCE) ---"
  up_args=(--provider "$PROVIDER" --instance "$INSTANCE"
    --dashboard-dist "$DASHBOARD_SRC/dist" --out cypress)
  case "$(printf '%s' "${EXTERNAL:-}" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes | on) up_args+=(--external) ;;
  esac
  "$MUSTER" up "${up_args[@]}"
fi

# Source the handoff.
eval "$("$MUSTER" env --provider "$PROVIDER" --instance "$INSTANCE" --out cypress)"
export TEST_BASE_URL API TEST_USERNAME CATTLE_BOOTSTRAP_PASSWORD TEST_PASSWORD
export HOST_UID="${HOST_UID:-$(id -u)}"
export HOST_GID="${HOST_GID:-$(id -g)}"

echo "--- Running Cypress setup (first-login) ---"
echo "    TEST_BASE_URL=$TEST_BASE_URL"
docker compose -f "$SCRIPT_DIR/docker-compose.yml" run --rm cypress-setup

echo "--- Running Cypress (GREP_TAGS=${GREP_TAGS:-<all>}) ---"
docker compose -f "$SCRIPT_DIR/docker-compose.yml" run --rm cypress "$@"
