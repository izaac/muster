# Troubleshooting

## `docker: command not found`

Docker Desktop is installed but the CLI binary is not on your `PATH`.
On macOS, Docker Desktop places its binaries in `~/.docker/bin/`:

```sh
export PATH="$HOME/.docker/bin:$PATH"   # add to ~/.zshrc for persistence
```

## `Cannot connect to the Docker daemon`

Docker Desktop is installed and on `PATH` but the daemon isn't running.
Start it before running muster:

```sh
open -a Docker          # macOS
# wait ~30 s for the engine to boot, then verify:
docker info
```

## `podman host needs the rootful socket`

muster is driving Podman but only the rootless socket is enabled. Rootless
cannot run Rancher (the jailer creates device nodes), so enable the system one:

```sh
sudo systemctl enable --now podman.socket
export DOCKER_HOST=unix:///run/podman/podman.sock
```

## `'release-X.Y' matched multiple remote tracking branches`

Your dashboard checkout has multiple remotes (e.g. `origin` + `upstream`) that
both contain the target branch. Tell git which remote to prefer:

```sh
cd "$DASHBOARD_SRC"
git config checkout.defaultRemote upstream   # or origin, whichever is rancher/dashboard
```

## `--dashboard-src '~/repos/...' is not a git checkout`

The tilde `~` does **not** expand inside quotes. Use `$HOME` instead:

```sh
# ✗ broken
DASHBOARD_SRC="~/repos/dashboard/dashboard"

# ✓ works
DASHBOARD_SRC="$HOME/repos/dashboard/dashboard"
```

