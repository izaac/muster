# Upstream Cypress example

Runs the upstream `rancher/dashboard` Cypress suite against a
muster-provisioned Rancher. Builds a self-contained runner image and mounts
your dashboard checkout as the test source.

## Run

```sh
# Keep the cluster up for repeated runs
DASHBOARD_SRC=~/repos/dashboard GREP_TAGS='@navigation' ./run.sh

# One-shot: provision, run one tag, tear down
DASHBOARD_SRC=~/repos/dashboard ./one-shot.sh @navigation

# Provisioning tests need a public URL (cloudflared tunnel)
EXTERNAL=true DASHBOARD_SRC=~/repos/dashboard ./run.sh
```

`run.sh` provisions Rancher if needed, sources the muster handoff, runs the
first-login/EULA pass, then runs the specs. `one-shot.sh` builds the
dashboard dist first and tears down on exit.

## Browser

Chrome on Linux (GitHub Actions parity), Chromium on macOS. Override with
`CYPRESS_BROWSER=chrome|chromium|auto` and rebuild.

## Environment

- `DASHBOARD_SRC` (required): path to a `rancher/dashboard` checkout.
- `GREP_TAGS`: grep tag filter, e.g. `@generic` (one-shot default
  `@navigation`).
- `EXTERNAL`: `true` provisions a cloudflared tunnel.
