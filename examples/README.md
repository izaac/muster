# Examples

End-to-end test runners that consume a muster-provisioned Rancher. Each
example builds its own runner image and bind-mounts your test source, so the
only required input is the path to that checkout.

```sh
# Cypress (rancher/dashboard)
DASHBOARD_SRC=~/repos/dashboard GREP_TAGS='@navigation' \
  ./cypress-upstream/run.sh

# Playwright (dashboard-e2e-pw)
PW_REPO_PATH=~/repos/dashboard-e2e-pw GREP_TAGS='@navigation' \
  ./playwright/run.sh
```

Each `run.sh` provisions Rancher if needed, sources the muster handoff, and
runs the suite (cluster kept up). The matching `one-shot.sh` provisions,
runs one tag, then tears down. See each example's `README.md` for details.

- [`cypress-upstream/`](cypress-upstream/): Chrome on Linux, Chromium on
  macOS.
- [`playwright/`](playwright/): bundled Chromium on all platforms.
