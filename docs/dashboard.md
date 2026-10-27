# Dashboard UI and tests

## Building dashboard from a branch

Clone the dashboard repo and use `build-ui` to produce a dist, then mount it
into the Rancher instance so your UI changes are served locally:

```sh
# Build from head (master branch)
muster build-ui --dashboard-src ~/repos/dashboard --version head

# Build from a specific release branch (e.g. release-2.13)
muster build-ui --dashboard-src ~/repos/dashboard --version 2.13

# Build from an explicit branch name
muster build-ui --dashboard-src ~/repos/dashboard --dashboard-branch my-feature

# Bring up Rancher with the built dist mounted
muster up --provider k3d --dashboard-dist ~/repos/dashboard/dist
```

The `--version` flag derives the branch automatically (`head` → `master`,
`2.13` → `release-2.13`). Use `--dashboard-branch` to override with any
branch name.

## Choosing which UI is served

Rancher serves either the UI inside its image or one fetched from the dashboard
CDN, and `ui-offline-preferred` decides. `--ui-offline` sets that from the
command line instead of patching the cluster afterwards:

| Mode | What is served |
|---|---|
| `dynamic` (default) | the build decides: a release serves its image, a head build redirects to the CDN |
| `true` | the UI inside the image, so a run is reproducible with the image digest |
| `false` | the CDN, so a branch's continuously rebuilt UI is what is tested |
| `auto` | deploy `true`, then read which UI the image was built with from the running pod |

`auto` is for the head rows. A `-head` image does not imply a head UI: while a
patch is in development the image embeds its branch's UI, but once a patch ships
the pin is rewritten to the release tag for weeks afterwards. Serving that image
would swap the branch UI for a released one and mask a regression, so when the
running pod reports a released pin `muster` rolls the deployment to
`CATTLE_UI_OFFLINE_PREFERRED=false` and the CDN's branch UI is served instead.
The effective `ui-offline-preferred` setting is asserted after the rollout, so a
mode that never reached the deployment fails loudly rather than silently serving
the other UI.

```sh
muster up --dry-run --ui-offline auto --version v2.14-head
```

`--dashboard-dist` still wins: a mounted dist is served over the pod UI whatever
`--ui-offline` says.

## Running tests

muster emits a handoff that test frameworks consume directly; pick the format
with `--out`. The `env` handoff (default) emits `TEST_BASE_URL`,
`RANCHER_HOSTNAME`, `KUBECONFIG`, and `TEST_PASSWORD`. The `cypress` handoff
emits the vars `rancher/dashboard` Cypress reads in `cypress/base-config.ts`
(`TEST_BASE_URL`, `TEST_USERNAME`, `CATTLE_BOOTSTRAP_PASSWORD`, `TEST_PASSWORD`,
`API`).

```sh
muster up --provider k3d --out cypress
eval "$(muster env)"            # source the handoff into your shell
cd ~/repos/dashboard && yarn cypress run
```

To build a UI branch and test against it:

```sh
muster build-ui --dashboard-src ~/repos/dashboard --dashboard-branch my-feature
muster up --provider k3d --dashboard-dist ~/repos/dashboard/dist --out cypress
```

For fully containerized runners (no host Node/Cypress/Playwright install) see
[`examples/cypress-upstream/`](../examples/cypress-upstream/) and
[`examples/playwright/`](../examples/playwright/), which build their own images,
bind-mount your suite checkout, and document their own knobs.
