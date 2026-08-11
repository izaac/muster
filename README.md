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

# GA prime from registry.rancher.com, no credentials needed
muster up --provider k3d --repo rancher-prime-ga --version 2.14.4

# Resolve and print the chart, image and whether it is Prime; create nothing
muster up --dry-run --repo rancher-alpha --version 2.15

# Rolling head from the community alpha channel (default)
muster up --provider k3d --repo rancher-com-alpha --version head
```

### Testing a branch head on Prime

A branch head ships no chart of its own, so `--version head` on a Prime channel
resolves the newest chart in that channel and takes its tag, which is the last
alpha rather than the head build. `--image-tag` overrides the image while
leaving the chart alone:

```sh
# Newest Prime chart, running the current release-2.15 head build
muster up --provider k3d --repo rancher-alpha --version head \
  --image-tag v2.15.1-965e1896835ebcb961689a35f4bfe34e43ce2a4d-head
```

Prime head builds are tagged by commit, so the tag has to be looked up:

```sh
skopeo list-tags docker://stgregistry.suse.com/rancher/rancher \
  | grep -oE '"v2\.15[^"]*-head"'
```

Note that Prime publishes no master head. The 2.16 builds on the staging
registry report `RANCHER_VERSION_TYPE=` and are Community, so the newest Prime
head is on the highest cut release branch, not on master.

A value containing a `/` is taken as a full reference and moves the registry
too, which is how a chart from one channel is paired with an image from
another:

```sh
# Prime alpha chart, Community master head server
muster up --provider k3d --repo rancher-alpha --version head \
  --image-tag rancher/rancher:head
```

The chart pins the components while the server decides what it is, so that
pairing installs the Prime staging webhook and shell images under a Community
server that reports `RancherPrime: false`. It comes up and the UI works, which
is worth knowing in both directions: the chart channel is not a reliable
statement about the build, and a component set can be varied independently of
the server to reproduce a version skew.

### Channels

| `--repo` | Chart repository | Image | Notes |
|---|---|---|---|
| `rancher-prime` | `charts.rancher.com/server-charts/prime` | `registry.suse.com/rancher/rancher` | GA prime. |
| `rancher-prime-ga` | `charts.rancher.com/server-charts/prime` | `registry.rancher.com/rancher/rancher` | Same charts, prime images without credentials. |
| `rancher-latest` | `charts.optimus.rancher.io/server-charts/latest` | `stgregistry.suse.com/rancher/rancher` | Release candidates. |
| `rancher-alpha` | `charts.optimus.rancher.io/server-charts/alpha` | `stgregistry.suse.com/rancher/rancher` | Alphas; the newest builds of an unreleased line. |
| `rancher-com-rc` | `releases.rancher.com/server-charts/latest` | Docker Hub `rancher/rancher` | Community RC line. |
| `rancher-com-alpha` | `releases.rancher.com/server-charts/alpha` | Docker Hub `rancher/rancher` | Community alpha line. Default. |
| `rancher-community` | `releases.rancher.com/server-charts/stable` | Docker Hub `rancher/rancher` | Community stable. |

The staging channels publish freely pullable images and are the usual choice for
testing.

Two things about this table are not fixed and should not be relied on:

- **Prime is a property of the image, not of the channel.** Whether a build
  reports itself as Prime is what gates Prime-only UI extensions, and some tags
  served from a prime registry are community builds. Read it off the image with
  `--dry-run` rather than inferring it from the registry or the tag shape.
- **A release line reaches Docker Hub only up to a certain patch.** Later
  patches ship to the prime registries alone, so a version that exists may still
  be unreachable on a community channel. muster says so when that is why a
  lookup failed:

  ```
  $ muster up --dry-run --repo rancher-com-rc --version 2.14.4
  [muster] ERROR newest in rancher-com-rc: 2.15.0-rc1 ... 2.15.0-rc5
  [muster] ERROR Docker Hub carries the 2.14 line only up to 2.14.3; later
           patches go to the prime registries only. Try --repo rancher-prime-ga,
           or rancher-latest for a pre-release.
  [muster] ERROR no chart version in rancher-com-rc matches '2.14.4'
  ```

## Checking a version before running it

`--dry-run` answers "which build is this, and is it Prime" without creating
anything. It runs the same resolution the install does, so what it prints is
what a real run would use:

```sh
muster up --dry-run --repo rancher-prime-ga --version 2.14.4
```

```
[muster] plan only; nothing will be created
  provider         k3d
  instance         e2e
  external         false
  channel          rancher-prime-ga
  chart repo       https://charts.rancher.com/server-charts/prime
  chart version    2.14.4
  image            registry.rancher.com/rancher/rancher:v2.14.4
  flavour          prime  (Prime-only UI extensions will load)
  k3s image        driver default
  agent TLS        chart default
```

`flavour` is read from the image itself, not guessed:

| Value | Meaning |
|---|---|
| `prime` | Reports itself as Prime; Prime-only UI extensions will load. |
| `community` | Not a Prime build; Prime-only UI extensions will not load. |
| `missing` | That tag is not published in that registry. |
| `unknown` | Could not read the image (skopeo absent, or registry unreachable). |

Comparing channels before committing to one:

```sh
for repo in rancher-prime-ga rancher-latest rancher-alpha rancher-com-rc; do
  muster up --dry-run --repo "$repo" --version 2.14
done
```

```
rancher-prime-ga   registry.rancher.com/rancher/rancher:v2.14.4        prime
rancher-latest     stgregistry.suse.com/rancher/rancher:v2.14.4-rc1    prime
rancher-alpha      stgregistry.suse.com/rancher/rancher:v2.14.4-alpha7 prime
rancher-com-rc     no chart version matches (2.14 stops at 2.14.3 on Docker Hub)
```

`--dry-run` also runs the image preflight, so a tag that does not exist fails
here in a second or two rather than after the rollout wait has timed out.

## Kubernetes version

With `--provider k3d` and no `K3S_IMAGE` set, the k3d node image comes from
[`branches-metadata.json`](https://github.com/rancher/dashboard/blob/master/branches-metadata.json)
in `rancher/dashboard`, for the release line implied by `--version`. That is the
same Kubernetes version the dashboard team runs E2E on, so the UI is exercised
against what its suite was written for rather than a version that drifted.

An explicit `K3S_IMAGE` always wins, `MUSTER_IGNORE_BRANCH_METADATA=1` skips the
lookup, and an unreachable file or a branch without a pinned version quietly
leaves the built-in default. The lookup never fails a run.

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

## Troubleshooting

### `docker: command not found`

Docker Desktop is installed but the CLI binary is not on your `PATH`.
On macOS, Docker Desktop places its binaries in `~/.docker/bin/`:

```sh
export PATH="$HOME/.docker/bin:$PATH"   # add to ~/.zshrc for persistence
```

### `Cannot connect to the Docker daemon`

Docker Desktop is installed and on `PATH` but the daemon isn't running.
Start it before running muster:

```sh
open -a Docker          # macOS
# wait ~30 s for the engine to boot, then verify:
docker info
```

### `'release-X.Y' matched multiple remote tracking branches`

Your dashboard checkout has multiple remotes (e.g. `origin` + `upstream`) that
both contain the target branch. Tell git which remote to prefer:

```sh
cd "$DASHBOARD_SRC"
git config checkout.defaultRemote upstream   # or origin, whichever is rancher/dashboard
```

### `--dashboard-src '~/repos/...' is not a git checkout`

The tilde `~` does **not** expand inside quotes. Use `$HOME` instead:

```sh
# ✗ broken
DASHBOARD_SRC="~/repos/dashboard/dashboard"

# ✓ works
DASHBOARD_SRC="$HOME/repos/dashboard/dashboard"
```

## License

Apache-2.0. See [LICENSE](LICENSE).
