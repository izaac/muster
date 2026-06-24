#!/usr/bin/env bash
# Quick one-shot: provision + run upstream Cypress with a single tag.
# Does NOT keep cluster up between invocations (tears down after).
#
# Usage:
#   DASHBOARD_SRC=~/repos/dashboard ./one-shot.sh @navigation
#   EXTERNAL=true DASHBOARD_SRC=~/repos/dashboard ./one-shot.sh @provisioning
#
# To keep the cluster for repeated runs, use run.sh instead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MUSTER="$MUSTER_ROOT/muster"

: "${DASHBOARD_SRC:?set DASHBOARD_SRC to your rancher/dashboard checkout}"
: "${PROVIDER:=k3d}"
: "${INSTANCE:=e2e}"
GREP_TAGS="${1:-@navigation}"
export DASHBOARD_SRC GREP_TAGS PROVIDER INSTANCE

trap '"$MUSTER" down --provider "$PROVIDER" --instance "$INSTANCE"' EXIT

up_args=(--provider "$PROVIDER" --instance "$INSTANCE"
  --dashboard-dist "$DASHBOARD_SRC/dist" --out cypress)
case "$(printf '%s' "${EXTERNAL:-}" | tr '[:upper:]' '[:lower:]')" in
  1 | true | yes | on) up_args+=(--external) ;;
esac

"$MUSTER" build-ui --dashboard-src "$DASHBOARD_SRC" --version head
"$MUSTER" up "${up_args[@]}"

eval "$("$MUSTER" env --provider "$PROVIDER" --instance "$INSTANCE" --out cypress)"
export TEST_BASE_URL API TEST_USERNAME CATTLE_BOOTSTRAP_PASSWORD TEST_PASSWORD
HOST_UID="$(id -u)"; export HOST_UID
HOST_GID="$(id -g)"; export HOST_GID

echo "--- Running Cypress setup (first-login) ---"
docker compose -f "$SCRIPT_DIR/docker-compose.yml" run --rm cypress-setup

echo "--- Running Cypress (GREP_TAGS=$GREP_TAGS) ---"
docker compose -f "$SCRIPT_DIR/docker-compose.yml" run --rm cypress "$@"
