# Node 24 + Cypress 11.1.0 + Chromium (native arm64).
# Uses Debian chromium which has native arm64 builds — no Rosetta needed.
# On native x86 (CI/linux), use cypress/factory with google-chrome instead.
FROM node:24-bookworm-slim

# System deps Cypress/Chromium need.
RUN apt-get update && apt-get install -y --no-install-recommends \
      libgtk2.0-0 libgtk-3-0 libgbm-dev libnotify-dev libnss3 libxss1 \
      libasound2 libxtst6 xauth xvfb fonts-liberation \
      libatk-bridge2.0-0 libdrm2 libxcomposite1 libxdamage1 libxfixes3 \
      libxrandr2 libpango-1.0-0 libcairo2 libcups2 libdbus-1-3 \
      wget gnupg ca-certificates procps unzip \
      chromium \
    && rm -rf /var/lib/apt/lists/*

# Symlink so Cypress finds it as "chrome" family browser.
RUN ln -sf /usr/bin/chromium /usr/local/bin/google-chrome \
    && ln -sf /usr/bin/chromium /usr/local/bin/chrome

# Install Cypress 11.1.0 globally.
RUN npm install -g cypress@11.1.0 \
    && cypress install --force \
    && cypress verify

WORKDIR /e2e
