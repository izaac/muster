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
  Ships `k3d` and `existing`; `docker` is a deferred, honest stub.
- **Framework-agnostic handoff**: `--out env|cypress|json`. muster brings the
  Rancher up and sets the bootstrap password; each framework keeps owning its
  own first-login/setup spec.

## Usage

```sh
muster up --provider k3d                      # internal sslip.io Rancher
muster up --provider k3d --external           # public via cloudflared tunnel
muster up --provider existing --out cypress   # gate + hand off a running cluster
muster down                                   # tear down + sweep state
```

Copy `config.sh.example` to `config.sh` to set defaults; any flag overrides it.

## Requirements

`bash` 4+, `kubectl`, `helm`, and (for the k3d provider) `k3d`. External mode
fetches a pinned, checksum-verified `cloudflared`.

## Development

```sh
shellcheck -x -s bash muster lib/*.sh drivers/*.sh
shfmt -d -i 2 -ci -bn muster lib drivers
bats test/
```

## License

Apache-2.0. See [LICENSE](LICENSE).
