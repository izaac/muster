#!/usr/bin/env bash
# hooks/run-checks.sh - shared gate for the git hooks: shellcheck + shfmt + bats.
# Sourced by both pre-commit and pre-push so the two stay in lockstep with CI.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# Make locally installed shfmt/bats discoverable without polluting the user's
# shell profile (CI installs them on PATH; local dev often vendors them here).
export PATH="$HOME/.local/bin:$HOME/.local/bats-core/bin:$PATH"

scripts=(muster lib/*.sh drivers/*.sh hooks/*.sh hooks/pre-commit hooks/pre-push)

missing=0
need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "hook: required tool not found: $1" >&2
    missing=1
  fi
}
need shellcheck
need shfmt
need bats
if [ "$missing" -ne 0 ]; then
  echo "hook: install the missing tools (see README Development) and retry." >&2
  exit 1
fi

echo "hook: shellcheck"
shellcheck -x -s bash "${scripts[@]}"

echo "hook: shfmt"
shfmt -d -i 2 -ci -bn muster lib drivers hooks

echo "hook: bats"
bats test/

echo "hook: all checks passed"
