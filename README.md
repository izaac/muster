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

### Commands

| Command | What it does |
|---|---|
| `up` | Create/ensure a cluster, install Rancher, wait for readiness, hand off. |
| `down` | Tear down the cluster and sweep tunnel and substrate state. |
| `import` | Create a second k3d cluster and import it into the management Rancher. |
| `mirror` | Copy the images an airgapped install needs into a registry. |
| `build-ui` | Build a dashboard UI dist from the branch matching `--version`. |
| `wait` | Re-run the readiness gates against an instance that is already up. |
| `warmup` | Prime the provisioning controller to avoid the cold-start flake. |
| `tunnel` | Manage the cloudflared quick tunnel used by `--external`. |
| `env` | Print the consumer handoff for the current instance. |
| `show` | Print the resolved configuration, after config file and flags. |
| `version` | Print the muster version. |

`muster help` lists every flag.

## Documentation

| Guide | What is in it |
|---|---|
| [Channels and versions](docs/versions.md) | Picking a channel and version, the channel table, running a branch head on Prime, `--dry-run`, and where the Kubernetes version comes from. |
| [Self-resolving the nightly matrix](docs/matrix.md) | `--channel-source metadata`, and the reproducible commands a CI job runs for the head rows and the Prime rows. |
| [Airgapped installs](docs/airgap.md) | Mirroring, how the redirect works and why there is no upstream fallback, `systemDefaultRegistry` and the agent, cert-manager, and importing a downstream cluster. |
| [Dashboard UI and tests](docs/dashboard.md) | Building a UI dist from a branch, mounting it, and the Cypress/Playwright handoff. |
| [Troubleshooting](docs/troubleshooting.md) | The errors that have a known cause and a known fix. |

## Requirements

- `bash` 4+, and either Docker or Podman
- Podman works without a shim. muster detects a Podman host (a `docker` shim, or
  a podman socket in `DOCKER_HOST`) and points `DOCKER_HOST` at the **rootful**
  socket, because Rancher's jailer creates device nodes a rootless user cannot.
  An explicit rootful endpoint is left alone; `MUSTER_ROOTFUL_SOCK` overrides the
  path (default `/run/podman/podman.sock`).
- k3d provider: `k3d`, `helm`, `kubectl`
- docker provider: just `docker` (community channels); `helm` for staging/prime
- existing provider: `helm`, `kubectl`. Bring your own cluster: pass
  `--kubeconfig <path>` and `--rancher-host <hostname>` (or the `KUBECONFIG` /
  `RANCHER_HOST` env). muster installs Rancher via helm but never creates or
  deletes the cluster (`down` is a no-op). `--external` is unsupported here:
  `RANCHER_HOST` is already reachable, so there is no local port to tunnel.
- `mirror` / `--airgap` / `import`: `skopeo` (registry-to-registry copy), plus
  the k3d provider's `k3d`/`helm`/`kubectl`.
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
