#!/bin/sh
set -e

# Install project deps on first run. The named volume persists node_modules
# across runs so this only happens once.
if [ ! -d /app/node_modules/.bin ]; then
  echo "--- Installing project dependencies (first run) ---"
  yarn install --frozen-lockfile 2>/dev/null \
    || yarn install
fi

# Ensure the Chromium build Playwright expects is present. This is a no-op when
# the bundled browser already matches the project's Playwright version.
npx playwright install chromium >/dev/null 2>&1 || true

if [ "${1:-}" = "playwright-run" ]; then
  shift
  exec npx playwright test --reporter=line "$@"
fi

exec "$@"
