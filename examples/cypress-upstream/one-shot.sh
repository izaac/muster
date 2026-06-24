#!/usr/bin/env bash
# Quick one-shot: provision + run upstream Cypress with a single tag.
# Does NOT keep cluster up between invocations (tears down after).
#
# Usage:
#   DASHBOARD_SRC=~/repos/dashboard ./one-shot.sh @navigation
#   EXTERNAL=true DASHBOARD_SRC=~/repos/dashboard ./one-shot.sh @provisioning
#   CYPRESS_BROWSER=chromium DASHBOARD_SRC=~/repos/dashboard ./one-shot.sh @navigation
#   VERSION=2.13 REPO=rancher-latest DASHBOARD_SRC=~/repos/dashboard ./one-shot.sh @navigation
#
# Environment (besides DASHBOARD_SRC):
#   REPO             Rancher channel for `muster up` (e.g. rancher-com-rc,
#                    rancher-latest, rancher-alpha, rancher-prime).
#   VERSION          Rancher image/chart tag and dashboard build version
#                    (e.g. head, 2.13, 2.13.4-rc1). Default: head.
#   DASHBOARD_BRANCH Force the dashboard branch for build-ui (overrides the
#                    branch VERSION would derive).
#   EXTERNAL         Set to true for a cloudflared tunnel (provisioning tests).
#
# To keep the cluster for repeated runs, use run.sh instead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MUSTER_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MUSTER="$MUSTER_ROOT/muster"

: "${DASHBOARD_SRC:?set DASHBOARD_SRC to your rancher/dashboard checkout}"
: "${PROVIDER:=k3d}"
: "${INSTANCE:=e2e}"
: "${VERSION:=head}"
if [ "$#" -gt 0 ]; then
  GREP_TAGS="$1"
  shift
else
  GREP_TAGS="@navigation"
fi

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

export DASHBOARD_SRC GREP_TAGS PROVIDER INSTANCE CYPRESS_BROWSER

trap '"$MUSTER" down --provider "$PROVIDER" --instance "$INSTANCE"' EXIT

up_args=(--provider "$PROVIDER" --instance "$INSTANCE"
  --dashboard-dist "$DASHBOARD_SRC/dist" --out cypress)
[ -n "${REPO:-}" ] && up_args+=(--repo "$REPO")
up_args+=(--version "$VERSION")
case "$(printf '%s' "${EXTERNAL:-}" | tr '[:upper:]' '[:lower:]')" in
  1 | true | yes | on) up_args+=(--external) ;;
esac

build_args=(--dashboard-src "$DASHBOARD_SRC" --version "$VERSION")
[ -n "${DASHBOARD_BRANCH:-}" ] && build_args+=(--dashboard-branch "$DASHBOARD_BRANCH")
"$MUSTER" build-ui "${build_args[@]}"
"$MUSTER" up "${up_args[@]}"

eval "$("$MUSTER" env --provider "$PROVIDER" --instance "$INSTANCE" --out cypress)"
export TEST_BASE_URL API TEST_USERNAME CATTLE_BOOTSTRAP_PASSWORD TEST_PASSWORD
HOST_UID="$(id -u)"
export HOST_UID
HOST_GID="$(id -g)"
export HOST_GID

echo "--- Running Cypress setup (first-login) ---"
echo "    CYPRESS_BROWSER=$CYPRESS_BROWSER"
docker compose -f "$SCRIPT_DIR/docker-compose.yml" run --rm cypress-setup

echo "--- Running Cypress (GREP_TAGS=$GREP_TAGS) ---"
docker compose -f "$SCRIPT_DIR/docker-compose.yml" run --rm cypress cypress-run "$@"
