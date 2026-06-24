# Playwright example

Runs the `dashboard-e2e-pw` Playwright suite against a muster-provisioned
Rancher. Builds a self-contained runner image and mounts your suite
checkout as the test source.

## Run

```sh
# Keep the cluster up for repeated runs
PW_REPO_PATH=~/repos/dashboard-e2e-pw GREP_TAGS='@navigation' ./run.sh

# One-shot: provision, run one tag, tear down
PW_REPO_PATH=~/repos/dashboard-e2e-pw ./one-shot.sh @navigation

# Provisioning tests need a public URL (cloudflared tunnel)
EXTERNAL=true PW_REPO_PATH=~/repos/dashboard-e2e-pw ./run.sh
```

`run.sh` provisions Rancher if needed, sources the muster handoff, then runs
the suite. `one-shot.sh` tears down on exit.

## Browser

The Playwright base image bundles Chromium for amd64 and arm64, so there is
no host-specific browser split.

## Environment

- `PW_REPO_PATH` (required): path to a `dashboard-e2e-pw` checkout.
- `DASHBOARD_SRC`: path to a `rancher/dashboard` checkout; when set, its
  prebuilt `dist/` is mounted into Rancher (this example never builds a dist).
- `GREP_TAGS`: grep tag filter (one-shot default `@navigation`).
- `EXTERNAL`: `true` provisions a cloudflared tunnel.
- `FRESH`: `true` tears down and reprovisions the Rancher cluster. This
  example never builds a dist; set it when you want a clean cluster (a reused
  cluster keeps any previously mounted dist).
- `REPO`: Rancher channel for `muster up` (`rancher-com-rc`, `rancher-latest`,
  `rancher-alpha`, `rancher-prime`, ...).
- `VERSION`: Rancher image/chart tag (`head`, `2.13`, `2.13.4-rc1`). Defaults
  to `head`.

To discover valid `REPO` / `VERSION` pairs for a minor, use
[list-rancher-versions](https://github.com/izaac/list-rancher-versions):

```sh
./list-rancher-versions.sh 2.13   # chart/image combos per channel
```
