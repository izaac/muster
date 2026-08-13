# Airgapped installs

An airgapped install pulls every image from a private registry instead of the
internet, the way a customer behind a sealed network does. muster reproduces
that locally so the install path can be tested without a real airgap:

```sh
# 1. Fill a local registry with everything the install needs
muster mirror --registry localhost:5000 --insecure-registry --version 2.14 --repo rancher-latest

# 2. Install with every pull resolved through that registry
muster up --airgap --registry localhost:5000 --insecure-registry --version 2.14 --repo rancher-latest
```

`mirror` copies (with skopeo, registry to registry, no daemon or tarball) the
server image at the tag that actually resolved, the matching `rancher-agent`, the
core images a Rancher server needs to serve its UI and provision a k3s cluster,
and the cert-manager chart and images. `--mirror-all` copies the whole published
list; `--mirror-extension` (or `--k3k-version <tag>`) adds the K3K images the
virtual-clusters extension needs, along with `--k3s-versions <n>` k3s releases so
a virtual cluster can be created at any of them; `--from-cluster` copies exactly
what a running cluster is still asking for, which fills the gaps a prerelease
server pulls that no published list names.

## How the redirect works

The redirect happens at two layers, and it is worth being precise about which
does what, because the image names in `kubectl get pods` stay upstream
(`quay.io/...`, `stgregistry.suse.com/...`) even though nothing is pulled from
there:

- **The container runtime under muster (Docker or Podman)** runs the k3d node
  containers *and* the registry container, and puts them on one network. Its only
  job in the redirect is name resolution: it makes `muster-registry-<instance>`
  resolve to the registry container from inside the nodes. It does **not** rewrite
  any image reference.
- **containerd, inside each k3s node**, is what actually redirects. It reads a
  per-registry `hosts.toml` from its `certs.d` config path, one for every upstream
  registry, each pointing only at the mirror:

  ```toml
  # certs.d/quay.io/hosts.toml  (and docker.io, ghcr.io, registry.suse.com,
  # stgregistry.suse.com, registry.rancher.com, and the mirror itself)
  [host."http://muster-registry-e2e:5000/v2"]
    capabilities = ["pull", "resolve"]
    skip_verify = true
  ```

  So a pod that names `quay.io/jetstack/cert-manager-controller` is pulled from
  `muster-registry-e2e:5000/jetstack/cert-manager-controller`. The name is
  cosmetic; the pull goes to the mirror.

  There is deliberately **no `server` line**. k3s's own `registries.yaml`
  generation always adds `server = <upstream>`, which containerd treats as a
  fallback and tries whenever the mirror answers 404, so an image the mirror does
  not have would be pulled from the internet and a mirror gap would pass as green.
  muster writes the `hosts.toml` files directly, without that fallback, so a
  missing image fails as a 404 that names it. That is the point of an airgap test:
  every image must come from the mirror, and anything absent must fail loudly
  rather than silently reach out.

muster generates that `certs.d` tree (`airgap_write_certs_d`) and bind-mounts it
into the node at containerd's registry config path, and it attaches the registry
container to the cluster network so the nodes can reach it by name. The registry
is addressed by container name rather than a published `localhost` port because
the
nodes are themselves containers, so `localhost` would be their own, and this is
closer to how a real airgapped environment reaches its registry.

Mirroring at the runtime rather than only through `systemDefaultRegistry` is
deliberate: it leaves image names alone, so a missing image fails as a plain pull
error naming the image that was forgotten, rather than looking like a Rancher
misconfiguration.

## systemDefaultRegistry, and the agent

The one reference this does not cover cleanly is the cluster agent. Rancher
prefixes `systemDefaultRegistry` onto `CATTLE_AGENT_IMAGE`, so a fully qualified
agent image would become `<mirror>/stgregistry.suse.com/rancher/rancher-agent`, a
path the mirror does not carry (it keeps the repository path only). The server
image is fine because containerd redirects it by swapping its *host*; the agent
reference is built by Rancher and never passes through that swap. muster therefore
hands the agent its bare repository path (`rancher/rancher-agent`) in airgap mode,
so the prefix resolves to `<mirror>/rancher/rancher-agent`, which the mirror has.

## cert-manager

cert-manager is the one host-side fetch an airgapped install otherwise still made
(its CRD manifest from a GitHub release). In airgap mode muster installs it from
the mirrored OCI chart (`oci://<registry>/jetstack/charts/cert-manager`) with the
chart's own `crds.enabled=true`, so nothing is fetched from `charts.jetstack.io`
or GitHub. Outside airgap the CRD manifest is still downloaded and SHA256-verified
against a pinned checksum before it is applied.

## Importing a downstream cluster

Node-driver provisioning cannot work in an airgap: there is no cloud to reach. To
give a management Rancher a real downstream cluster to work with, `import` stands
up a second k3d cluster and imports it:

```sh
muster import --airgap --registry localhost:5000 --insecure-registry --version 2.14 --repo rancher-latest
```

The downstream joins the management cluster's own network, so its nodes reach the
same mirror by name and its agent reaches the management Rancher. In airgap it is
handed the same `certs.d` tree, with no upstream fallback, so every image it
pulls, including the agent, comes from the mirror and a gap fails loudly rather
than reaching the internet. `import` registers the cluster in Rancher, fetches the
registration manifest (reading the token from the Secret Rancher references, which
is where current Rancher keeps it), applies it to the downstream, and waits for
the cluster to report Active. `--import-instance e2e-<n>` names the downstream;
by default it is the first free one. Tear it down with `muster down --instance
e2e-<n>`.


For picking a channel by hand instead, see [Channels and versions](versions.md).
