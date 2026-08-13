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
