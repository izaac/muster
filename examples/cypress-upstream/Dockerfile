# Node 24 + Cypress 11.1.0 + browser selected by platform.
#
# GitHub Actions parity is Linux + Google Chrome. Docker Desktop for macOS is
# local-only and uses Chromium via the wrapper scripts. Set
# CYPRESS_BROWSER=chrome|chromium|auto to override, then rebuild.
FROM node:24-bookworm-slim

ARG TARGETARCH
ARG CYPRESS_BROWSER=auto

# System deps Cypress and browsers need.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgtk2.0-0 libgtk-3-0 libgbm-dev libnotify-dev libnss3 libxss1 \
      libasound2 libxtst6 xauth xvfb fonts-liberation \
      libatk-bridge2.0-0 libdrm2 libxcomposite1 libxdamage1 libxfixes3 \
      libxrandr2 libpango-1.0-0 libcairo2 libcups2 libdbus-1-3 \
      wget gnupg ca-certificates procps unzip \
    && rm -rf /var/lib/apt/lists/*

# Install the browser. auto chooses Chrome on amd64 and Chromium on arm64; the
# run scripts pass chromium on macOS so Intel Macs do not use the Linux default.
RUN set -eux; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    case "$arch" in \
      amd64 | x86_64) arch=amd64 ;; \
      arm64 | aarch64) arch=arm64 ;; \
      *) echo "unsupported TARGETARCH '$arch' (amd64|arm64)" >&2; exit 1 ;; \
    esac; \
    browser="$CYPRESS_BROWSER"; \
    if [ "$browser" = auto ]; then \
      if [ "$arch" = arm64 ]; then browser=chromium; else browser=chrome; fi; \
    fi; \
    case "$browser" in \
      chrome | google-chrome) \
        if [ "$arch" != amd64 ]; then \
          echo "Google Chrome is only available for linux/amd64; use CYPRESS_BROWSER=chromium" >&2; \
          exit 1; \
        fi; \
        install -d -m 0755 /etc/apt/keyrings; \
        wget -qO- https://dl.google.com/linux/linux_signing_key.pub \
          | gpg --dearmor -o /etc/apt/keyrings/google-linux.gpg; \
        echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-linux.gpg] https://dl.google.com/linux/chrome/deb/ stable main" \
          > /etc/apt/sources.list.d/google-chrome.list; \
        apt-get update; \
        apt-get install -y --no-install-recommends google-chrome-stable; \
        ln -sf /usr/bin/google-chrome /usr/local/bin/chrome; \
        echo chrome > /usr/local/share/cypress-browser; \
        ;; \
      chromium) \
        apt-get update; \
        apt-get install -y --no-install-recommends chromium; \
        ln -sf /usr/bin/chromium /usr/local/bin/chrome; \
        ln -sf /usr/bin/chromium /usr/local/bin/google-chrome; \
        echo chromium > /usr/local/share/cypress-browser; \
        ;; \
      *) \
        echo "unsupported CYPRESS_BROWSER '$browser' (chrome|chromium|auto)" >&2; \
        exit 1; \
        ;; \
    esac; \
    rm -rf /var/lib/apt/lists/*

# Install Cypress 11.1.0 globally.
RUN npm install -g cypress@11.1.0 \
    && cypress install --force \
    && cypress verify

WORKDIR /e2e
