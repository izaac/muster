# muster

Wrangle a Rancher management cluster for any E2E framework. Quick k3d or
existing-cluster bring-up, internal or external, with a clean handoff to the
test framework of your choice (Playwright, Cypress, or a human at a browser).

> **muster** (v.) to round up the herd before work, and to assemble something
> into service. That is the job: gather a Rancher into a ready state, then hand
> it off.

## Status

Early development. The CLI surface, driver contract, and config schema are
landing in phases (see `muster help`). Phase 0 ships the scaffold: dispatcher,
strict-mode core utilities, the driver contract, CI, and tests. Provisioning
logic is ported in from a proven Playwright e2e provisioner over Phases 1-4.

## Design

- **Provider-blind core** (`lib/`): helm/version resolution, readiness gates,
  cloudflared tunnel, external-access patches, provisioning warm-up, and the
  consumer handoff. None of it knows which substrate it runs on.
- **Substrate drivers** (`drivers/`) behind a four-verb contract:
  `driver_up`, `driver_down`, `driver_kubeconfig`, `driver_endpoint`.
  Ships `k3d` (helm chart on k3s-in-docker) and `docker` (standalone
  `rancher/rancher` container, no helm/k8s cluster); `existing` is a deferred,
  honest stub. Drivers may declare optional hooks (`driver_installs_rancher`,
  `driver_gate`, `driver_resolve_image`, `driver_settle`) so a self-contained
  substrate like docker opts out of the core's helm path cleanly.
- **Framework-agnostic handoff**: `--out env|cypress|json`. muster brings the
  Rancher up and sets the bootstrap password; each framework keeps owning its
  own first-login/setup spec.

## Usage

```sh
muster up --provider k3d                      # internal sslip.io Rancher (helm chart)
muster up --provider docker                   # standalone rancher/rancher container
muster up --provider k3d --external           # public via cloudflared tunnel
muster up --provider existing --out cypress   # gate + hand off a running cluster
muster down                                   # tear down + sweep state
```

Copy `config.sh.example` to `config.sh` to set defaults; any flag overrides it.

## Providers

muster ships two working substrate drivers behind the same four-verb contract
(`driver_up`, `driver_down`, `driver_kubeconfig`, `driver_endpoint`). A driver
may declare optional hooks so a self-contained substrate opts out of the
core's helm path cleanly.

### k3d

The strategic substrate. Provisions a k3s cluster in docker, installs
cert-manager and the Rancher helm chart, then runs kubectl-based readiness
gates (deployment rollout, webhook pod, capi service). Needs `k3d`, `helm`,
and `kubectl`. Use this when you want the real post-install Rancher form,
matching upstream e2e-k3s-start values.

### docker

Runs `rancher/rancher` as a single privileged container, the pre-k3d install
form. No k8s cluster, no helm chart, no cert-manager. The container IS
Rancher. The driver declares three optional hooks so the provider-blind core
skips helm cleanly: `driver_installs_rancher` makes `cmd_up` skip the chart
install, `driver_gate` runs HTTP-only readiness (dashboard 200 and auth API
200, no kubectl), and `driver_resolve_image` resolves the image tag from the
same channel map as k3d.

Community channels (`rancher-com-rc`, `rancher-community`, `rancher-com-alpha`)
are fully helm-free: the literal tag goes straight to `docker run`, so
`rancher/rancher:head` works with just docker installed. Staging and prime
channels (`rancher-latest`, `rancher-alpha`, `rancher-prime`) still need helm
to resolve `v<chart_version>` for the image tag, but never for an install.

`driver_kubeconfig` prints empty since standalone Rancher exposes no consumer
kubeconfig. The handoff omits `KUBECONFIG` accordingly; the e2e framework
only needs `TEST_BASE_URL` and the bootstrap password.

### Sharding

Both providers offset host ports by instance index so sharded runs do not
collide: `e2e` maps to 8443, `e2e-1` to 8444, `e2e-2` to 8445. Use
`--instance e2e-<n>` for parallel runs. Note that k3d and docker share the
same offset scheme, so the default instance of both cannot run simultaneously.

### External mode

Both providers support `--external`, which starts a pinned, checksum-verified
cloudflared quick tunnel to the local Rancher and exports the public
`*.trycloudflare.com` URL as `EXTERNAL_HOSTNAME`. The handoff then emits the
tunnel URL as `TEST_BASE_URL` so an out-of-cluster node can register. This is
the path for provisioning tests that need a publicly reachable Rancher.

## Requirements

`bash` 4+, `kubectl`, `helm`, and (for the k3d provider) `k3d`. The docker
provider needs only `docker` for community channels (`rancher/rancher:head`);
staging/prime channels still need `helm` to resolve the image tag. External
mode fetches a pinned, checksum-verified `cloudflared`.

## Development

```sh
shellcheck -x -s bash muster lib/*.sh drivers/*.sh
shfmt -d -i 2 -ci -bn muster lib drivers
bats test/
```

### Git hooks

The repo ships native git hooks (no external hook manager) under `hooks/`. They
run the same shellcheck + shfmt + bats suite as CI, on both commit and push, so
a failing test blocks the push. Enable them once per clone:

```sh
git config core.hooksPath hooks
```

The hooks look for `shfmt` and `bats` on `PATH` and in `~/.local/bin` /
`~/.local/bats-core/bin`; install them there if they are not already available.

## License

Apache-2.0. See [LICENSE](LICENSE).
