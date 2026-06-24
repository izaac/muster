# muster

Wrangle a Rancher management cluster for E2E testing. Brings up Rancher
(k3d helm chart or standalone docker container), waits for readiness, and
hands off to Cypress, Playwright, or a human at a browser.

## Install

```sh
git clone https://github.com/izaac/muster && cd muster
./install.sh          # per-user: ~/.local/share/muster + ~/.local/bin/muster
```

Works on Linux and macOS with no extra tooling (it is bash all the way down).
The script copies the tree into a library directory and symlinks the `muster`
entrypoint onto your PATH, so **upgrading is just `git pull && ./install.sh`**.
For a system-wide install use `PREFIX=/usr/local ./install.sh` (may need
`sudo`); remove everything with `./install.sh --uninstall`. Shell completions
are installed automatically (see [Shell completion](#shell-completion)).

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
[`examples/cypress-upstream/`](examples/cypress-upstream/) and
[`examples/playwright/`](examples/playwright/), which build their own images,
bind-mount your suite checkout, and document their own knobs.

## Requirements

- `bash` 4+, `docker`
- k3d provider: `k3d`, `helm`, `kubectl`
- docker provider: just `docker` (community channels); `helm` for staging/prime
- existing provider: `helm`, `kubectl`. Bring your own cluster: pass
  `--kubeconfig <path>` and `--rancher-host <hostname>` (or the `KUBECONFIG` /
  `RANCHER_HOST` env). muster installs Rancher via helm but never creates or
  deletes the cluster (`down` is a no-op). `--external` is unsupported here:
  `RANCHER_HOST` is already reachable, so there is no local port to tunnel.
- `build-ui`: no host Node needed. muster builds with the exact Node major the
  dashboard branch pins (`.nvmrc`, else `engines.node`), fetching a
  checksum-verified Node plus `yarn` into its cache when the host major differs;
  `--node-bin <dir>` overrides.
- External mode auto-fetches a pinned `cloudflared`

## Development

```sh
shellcheck -x -s bash muster lib/*.sh drivers/*.sh docker/*.sh examples/*/*.sh
shfmt -d -i 2 -ci -bn muster lib drivers docker/*.sh examples/*/*.sh
bats test/
git config core.hooksPath hooks   # enable pre-commit/pre-push checks
```

## Shell completion

Tab-completion for commands, flags, and known values (providers, channels,
handoff formats) ships in `completions/`.

```sh
# bash: source it from ~/.bashrc, or install into a bash-completion dir
cp completions/muster.bash ~/.local/share/bash-completion/completions/muster

# zsh: put it on your $fpath as _muster, then rebuild the completion cache
mkdir -p ~/.zfunc && cp completions/_muster ~/.zfunc/_muster
echo 'fpath=(~/.zfunc $fpath); autoload -U compinit && compinit' >> ~/.zshrc
```

## License

Apache-2.0. See [LICENSE](LICENSE).
