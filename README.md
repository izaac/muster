# muster

Wrangle a Rancher management cluster for E2E testing. Brings up Rancher
(k3d helm chart or standalone docker container), waits for readiness, and
hands off to Cypress, Playwright, or a human at a browser.

## Quick start

```sh
muster up --provider k3d                    # helm chart on k3s-in-docker
muster up --provider docker                 # standalone rancher/rancher container
muster up --provider existing \
  --kubeconfig ~/.kube/config --rancher-host rancher.example.com  # BYO cluster
muster up --provider k3d --external         # public via cloudflared tunnel
muster down                                 # tear down everything
```

Every knob resolves as `flag > config.sh > environment > built-in default`.
Copy `config.sh.example` → `config.sh` for defaults, export env vars, or pass
flags; the most specific wins.

## Choosing a Rancher channel and version

`--repo` selects the helm channel and image registry; `--version` selects the
chart/image tag (`head` or a concrete version like `2.13` / `2.13.4-rc1`):

```sh
# Latest RC of the 2.13 line from the staging channel
muster up --provider k3d --repo rancher-latest --version 2.13

# A specific prime release (gated registry; needs pull creds out of band)
muster up --provider k3d --repo rancher-prime --version 2.13.4

# Rolling head from the community channel (default)
muster up --provider k3d --repo rancher-com-rc --version head
```

Channels: `rancher-prime`, `rancher-latest`, `rancher-alpha`,
`rancher-community`, `rancher-com-rc` (default), `rancher-com-alpha`. The
alpha/rc staging channels publish freely pullable images and are the happy
path for testing; prime is gated.

To list the chart/image combinations available for a minor across every
channel, use
[list-rancher-versions](https://github.com/izaac/list-rancher-versions):

```sh
./list-rancher-versions.sh 2.13   # every 2.13.x chart/image combo per channel
```

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

muster emits a handoff that test frameworks consume directly. Use `--out` to
select the format.

### Upstream Cypress (rancher/dashboard)

```sh
# Bring up Rancher with cypress handoff
muster up --provider k3d --out cypress

# Source the handoff and run tests
eval "$(muster env)"
cd ~/repos/dashboard
yarn cypress run
```

The `cypress` handoff emits `TEST_BASE_URL`, `TEST_USERNAME`,
`CATTLE_BOOTSTRAP_PASSWORD`, `TEST_PASSWORD`, and `API`: the same env vars
`rancher/dashboard` Cypress expects in `cypress/base-config.ts`.

For a fully containerized runner (no host Node/Cypress install), see
[`examples/cypress-upstream/`](examples/cypress-upstream/), which builds
Chrome on Linux and Chromium on macOS.

The upstream Cypress example targets GitHub Actions parity on Linux with Google
Chrome. macOS local Docker Desktop uses Chromium. Override with
`CYPRESS_BROWSER=chrome` or `CYPRESS_BROWSER=chromium`, then rebuild the
example image.

### Playwright (izaac/dashboard-e2e-pw)

```sh
# Bring up Rancher with env handoff (default)
muster up --provider k3d --out env

# Source the handoff and run Playwright tests
eval "$(muster env)"
cd ~/repos/dashboard-e2e-pw
yarn playwright test
```

The `env` handoff emits `TEST_BASE_URL`, `RANCHER_HOSTNAME`, `KUBECONFIG`,
and `TEST_PASSWORD`.

For a fully containerized runner, see [`examples/playwright/`](examples/playwright/),
which builds a self-contained image and bind-mounts your suite checkout.

### With a custom dashboard build

Combine both, build your UI branch and run tests against it:

```sh
muster build-ui --dashboard-src ~/repos/dashboard --dashboard-branch my-feature
muster up --provider k3d --dashboard-dist ~/repos/dashboard/dist --out cypress
eval "$(muster env)"
cd ~/repos/dashboard && yarn cypress run
```

## Requirements

- `bash` 4+, `docker`
- k3d provider: `k3d`, `helm`, `kubectl`
- docker provider: just `docker` (community channels); `helm` for staging/prime
- existing provider: `helm`, `kubectl`. Bring your own cluster: pass
  `--kubeconfig <path>` and `--rancher-host <hostname>` (or the `KUBECONFIG` /
  `RANCHER_HOST` env). muster installs Rancher via helm but never creates or
  deletes the cluster (`down` is a no-op). `--external` is unsupported here:
  `RANCHER_HOST` is already reachable, so there is no local port to tunnel.
- `build-ui`: nothing extra in the common case. muster reads the Node version
  the dashboard branch pins (`.nvmrc`, falling back to `engines.node`) and, when
  the host Node is a different major, downloads a checksum-verified Node plus a
  matching `yarn` into its cache and builds with those. So `master` builds on
  Node 24 and `release-2.14` on Node 20 with no host setup. A host `node` of the
  right major is reused as-is; `--node-bin <dir>` forces a specific toolchain.
- External mode auto-fetches a pinned `cloudflared`

## Development

```sh
shellcheck -x -s bash muster lib/*.sh drivers/*.sh docker/*.sh examples/*/*.sh
shfmt -d -i 2 -ci -bn muster lib drivers docker/*.sh examples/*/*.sh
bats test/
git config core.hooksPath hooks   # enable pre-commit/pre-push checks
```

## License

Apache-2.0. See [LICENSE](LICENSE).
