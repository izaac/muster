#!/usr/bin/env bash
# Quick one-shot: provision + run Playwright with a single tag.
# Does NOT keep cluster up between invocations (tears down after).
#
# Usage:
#   PW_REPO_PATH=~/repos/dashboard-e2e-pw ./one-shot.sh @navigation
#   EXTERNAL=true PW_REPO_PATH=~/repos/dashboard-e2e-pw ./one-shot.sh @provisioning
#   VERSION=2.13 REPO=rancher-latest PW_REPO_PATH=~/repos/dashboard-e2e-pw ./one-shot.sh @navigation
#
# Environment (besides PW_REPO_PATH):
#   REPO     Rancher channel for `muster up` (e.g. rancher-com-rc,
#            rancher-latest, rancher-alpha, rancher-prime).
#   VERSION  Rancher image/chart tag for `muster up` (e.g. head, 2.13,
#            2.13.4-rc1). Default: the muster default (head).
#   EXTERNAL Set to true for a cloudflared tunnel (provisioning tests).
#
# To keep the cluster for repeated runs, use run.sh instead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MUSTER="$MUSTER_ROOT/muster"

: "${PW_REPO_PATH:?set PW_REPO_PATH to your dashboard-e2e-pw checkout}"
: "${PROVIDER:=k3d}"
: "${INSTANCE:=e2e}"
GREP_TAGS="${1:-@navigation}"
export PW_REPO_PATH GREP_TAGS PROVIDER INSTANCE

trap '"$MUSTER" down --provider "$PROVIDER" --instance "$INSTANCE"' EXIT

up_args=(--provider "$PROVIDER" --instance "$INSTANCE" --out cypress)
[ -n "${REPO:-}" ] && up_args+=(--repo "$REPO")
[ -n "${VERSION:-}" ] && up_args+=(--version "$VERSION")
case "$(printf '%s' "${EXTERNAL:-}" | tr '[:upper:]' '[:lower:]')" in
  1 | true | yes | on) up_args+=(--external) ;;
esac

"$MUSTER" up "${up_args[@]}"

eval "$("$MUSTER" env --provider "$PROVIDER" --instance "$INSTANCE" --out cypress)"
export TEST_BASE_URL CATTLE_BOOTSTRAP_PASSWORD TEST_PASSWORD TEST_USERNAME
HOST_UID="$(id -u)"
export HOST_UID
HOST_GID="$(id -g)"
export HOST_GID

mkdir -p "$PW_REPO_PATH/test-results" "$PW_REPO_PATH/playwright-report"

echo "--- Running Playwright (GREP_TAGS=$GREP_TAGS) ---"
docker compose -f "$SCRIPT_DIR/docker-compose.yml" run --rm tests playwright-run "$@"
