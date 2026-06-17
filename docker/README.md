# muster container image

A single multi-arch image (`linux/amd64` + `linux/arm64`) that carries muster and
its pinned toolchain (k3d, helm, kubectl, node, yarn, the Docker CLI and gosu). Any
host with Docker can run muster identically, with no host dependency on bash, k3d,
helm or node. This makes the same provisioning flow reproducible on macOS, Windows
(WSL2) and Linux.

## How it works

muster does not run Docker inside the container. k3d inside the container talks to
the **host** Docker daemon over a bind-mounted socket and creates **sibling**
containers (not docker-in-docker). The k3s nodes are therefore peers of the muster
container on the host daemon.

Because k3d bind-mounts originate on the host, any path passed to `--dashboard-dist`
must be a **host path** that the host daemon can see, not a path that only exists
inside the muster container.

## Security posture

- Base image `registry.suse.com/bci/bci-base:15.6` is pinned by digest.
- Every downloaded tool is pinned to an exact version and SHA256 and verified
  fail-closed at build time (`docker/install-tools.sh`).
- The container process runs as the unprivileged `muster` user. It starts as root
  only briefly so the entrypoint can grant that user access to the bind-mounted
  Docker socket, then drops privileges with gosu.
- No secrets are baked in. The bootstrap password is a runtime input.

### Socket group handling

The Docker socket's owning GID differs by platform: a numbered `docker` group on
Linux, root (GID 0) on Docker Desktop for macOS and Windows. The entrypoint detects
the socket's GID and adds the `muster` user to the matching group before dropping
privileges, so the same image works on every platform without `--user` tuning.

If you prefer to manage this yourself, pass `--user` and `--group-add` explicitly;
the entrypoint sees it is already non-root and skips the privileged step.

## Build

Single-arch (local):

```sh
docker build -f docker/Dockerfile --build-arg TARGETARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') -t muster:dev .
```

Multi-arch (buildx):

```sh
docker buildx build -f docker/Dockerfile \
  --platform linux/amd64,linux/arm64 \
  -t ghcr.io/izaac/muster:latest --push .
```

`TARGETARCH` is supplied automatically by buildx per platform.

## Run

Show help:

```sh
docker run --rm muster:dev
```

Bring up a Rancher management cluster (mount the Docker socket so k3d can reach the
host daemon):

```sh
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  muster:dev up e2e
```

Build the dashboard UI from a matching branch and mount the dist (host path):

```sh
docker run --rm \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$HOME/repos/dashboard":/dashboard-src \
  muster:dev build-ui --dashboard-src /dashboard-src
```
