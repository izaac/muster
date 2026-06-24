#!/bin/sh
set -e

# Enable yarn via corepack (cypress/factory ships corepack but not yarn).
if ! command -v yarn >/dev/null 2>&1; then
  corepack enable 2>/dev/null || true
fi

# Install project deps on first run. The named volume persists node_modules
# across runs so this only happens once.
if [ ! -d /e2e/node_modules/.bin ]; then
  echo "--- Installing project dependencies (first run) ---"
  yarn install --frozen-lockfile --ignore-engines 2>/dev/null \
    || yarn install --ignore-engines
fi

exec "$@"
