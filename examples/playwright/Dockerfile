# Self-contained Playwright runner for the rancher dashboard-e2e-pw suite.
#
# The Microsoft Playwright base image already ships Node, yarn, and the bundled
# browsers (Chromium, Firefox, WebKit) for both amd64 and arm64, so unlike the
# Cypress example there is no host-specific browser split. Project sources and
# node_modules are provided at runtime via a bind mount and a named volume, so
# this image stays generic and does not embed a particular checkout.
#
# Keep this tag in sync with the @playwright/test version pinned in the
# dashboard-e2e-pw package.json so the bundled browsers match.
FROM mcr.microsoft.com/playwright:v1.52.0-noble

WORKDIR /app
