#!/bin/sh
set -e

# Normalize the browser name. "auto" uses the browser baked into the image.
case "${CYPRESS_BROWSER:-auto}" in
  auto)
    CYPRESS_BROWSER="$(cat /usr/local/share/cypress-browser)"
    ;;
  chrome | chromium) ;;
  google-chrome)
    CYPRESS_BROWSER=chrome
    ;;
  *)
    echo "unsupported CYPRESS_BROWSER '${CYPRESS_BROWSER}' (chrome|chromium|auto)" >&2
    exit 1
    ;;
esac
export CYPRESS_BROWSER

case "$CYPRESS_BROWSER" in
  chrome)
    command -v google-chrome >/dev/null 2>&1 \
      || command -v chrome >/dev/null 2>&1 \
      || {
        echo "Chrome is not installed in this image; rebuild with CYPRESS_BROWSER=chrome" >&2
        exit 1
      }
    ;;
  chromium)
    command -v chromium >/dev/null 2>&1 \
      || {
        echo "Chromium is not installed in this image; rebuild with CYPRESS_BROWSER=chromium" >&2
        exit 1
      }
    ;;
esac

# Enable yarn via corepack (the Node image ships corepack but not yarn).
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

if [ "${1:-}" = "cypress-run" ]; then
  shift
  exec npx cypress run --browser "$CYPRESS_BROWSER" "$@"
fi

exec "$@"
