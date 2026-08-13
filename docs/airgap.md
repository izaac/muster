# Airgapped installs

An airgapped install runs behind a sealed network: every image comes from a
private registry, and nothing in the cluster can reach the internet at all.
muster reproduces both halves locally, so the install path can be tested without
a real airgap:

```sh
# 1. Fill a local registry with everything the install needs
muster mirror --registry localhost:5000 --insecure-registry --version 2.14 --repo rancher-latest

# 2. Install with every pull resolved through that registry, on a sealed network
muster up --airgap --registry localhost:5000 --insecure-registry --version 2.14 --repo rancher-latest
```

Both halves matter. Mirroring alone only seals image pulls; everything else a
Rancher server does, calling an API, fetching a chart index, phoning home, would
still reach out, and a behaviour that quietly depends on the internet would pass
as green.

`mirror` copies (with skopeo, registry to registry, no daemon or tarball) the
server image at the tag that actually resolved, the matching `rancher-agent`, the
core images a Rancher server needs to serve its UI and provision a k3s cluster,
and the cert-manager chart and images. `--mirror-all` copies the whole published
list; `--mirror-extension` (or `--k3k-version <tag>`) adds the K3K images the
virtual-clusters extension needs, along with `--k3s-versions <n>` k3s releases so
a virtual cluster can be created at any of them; `--from-cluster` copies exactly
what a running cluster is still asking for, which fills the gaps a prerelease
server pulls that no published list names.

## The network: no way out, one way in

muster creates the cluster network itself and then, once the nodes are up,
removes their default route. The result is the shape a real airgapped site has:

| Path | Works? | Why |
|---|---|---|
| Node or pod to the internet | no | no default route, nothing off the subnet is reachable |
| Node to the mirror | yes | the registry is on the same subnet, addressed by container name |
| Node to node, pod to pod | yes | same subnet |
| Name resolution | yes | the runtime's resolver is the gateway address, which is on-link |
| Host to the Rancher UI | yes | the k3d load balancer publishes a host port |

That last row is the equivalent of the bastion and load balancer rules a real
airgapped environment is reached through: the nodes are not published, the load
balancer is, and it is the only way in.

The route is removed rather than the network being created `--internal`, because
an internal network has a gateway address but installs no default route, and k3s
refuses to start without one:

```
level=fatal msg="Error: no default routes found in /proc/net/route"
```

So the route has to exist while the node boots, and is taken away afterwards. One
consequence is worth knowing: a node container that is restarted boots without a
default route and k3s will fail with that same message. Rebuild the cluster
rather than restarting a node.

Verifying it on a running cluster:

```sh
# no default route on the node
docker exec k3d-e2e-server-0 ip route

# egress is refused, the mirror is not
docker exec k3d-e2e-server-0 wget -T5 -qO- https://1.1.1.1        # fails
docker exec k3d-e2e-server-0 wget -T5 -qO- http://muster-registry-e2e:5000/v2/   # 200
```

## Talking to the cluster

`muster env` prints everything needed to reach a running instance, so the usual
move is to source it:

```sh
eval "$(muster env)"        # sets KUBECONFIG, RANCHER_HOSTNAME, TEST_BASE_URL, TEST_PASSWORD
kubectl get nodes
```

```
NAME               STATUS   ROLES                  AGE   VERSION
k3d-e2e-server-0   Ready    control-plane,master   3m    v1.33.1+k3s1
```

Sealing the nodes does not affect this. The API server is published on a host
port, so the kubeconfig points at `https://0.0.0.0:<port>` on the host and the
connection never crosses the cluster's own network. The same holds for the
downstream, which keeps its own kubeconfig:

```sh
eval "$(muster env --instance e2e-1)"
kubectl get nodes
```

Without sourcing, `muster env` names the file it wrote, so it can be picked out
directly (`import` also prints the downstream's path when it creates it):

```sh
kubectl --kubeconfig "$(muster env | sed -n 's/^KUBECONFIG=//p')" get pods -A
```

## Connecting to Rancher

The UI is served through the k3d load balancer on a published host port, which is
the only way into the sealed network. `muster env` names it:

```sh
eval "$(muster env)"
echo "$TEST_BASE_URL"       # https://<lb-ip>.sslip.io/dashboard
echo "$TEST_PASSWORD"       # password1234 unless --password was given
```

Open `$TEST_BASE_URL` in a browser and log in as `admin` with `$TEST_PASSWORD`.
The certificate is self-signed, so the browser warns once.

The hostname is `<load-balancer-ip>.sslip.io`, which resolves to the load
balancer's address on the cluster network. That is a public DNS name resolved by
the host, not by the cluster, so it works while the cluster itself has no route
out.

Driving the API from the host works the same way:

```sh
TOKEN=$(curl -sk -X POST \
  "https://$RANCHER_HOSTNAME/v3-public/localProviders/local?action=login" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"$TEST_PASSWORD\"}" \
  | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

curl -sk -H "Authorization: Bearer $TOKEN" "https://$RANCHER_HOSTNAME/v3/clusters"
```

To reach it from another machine, put it on a public address with `--external`,
which fronts the instance with a cloudflared tunnel. That is a way in, not a way
out: the cluster still has no route to the internet.

## Adding images to the mirror

A pull the mirror does not cover fails, by design, with a 404 that names the
image. Three ways to close that gap, in the order they are usually reached for.

**From what the cluster is actually asking for.** This is the one to use after a
failure: it reads the running cluster and copies every image it references,
including the ones a prerelease server pulls that no published list names.

```sh
muster mirror --from-cluster --registry localhost:5000 --insecure-registry
```

**The whole published list**, when a run needs more than the core set muster
mirrors by default (every image the release ships, not only what a server needs
to serve its UI and provision a k3s cluster):

```sh
muster mirror --mirror-all --registry localhost:5000 --insecure-registry --version 2.14 --repo rancher-latest
```

**One image by hand**, with skopeo. The rule the mirror follows is that the
registry host is dropped and the repository path is kept, so
`docker.io/library/alpine:3.19` lands at `library/alpine:3.19`:

```sh
skopeo copy --dest-tls-verify=false \
  docker://docker.io/library/alpine:3.19 \
  docker://localhost:5000/library/alpine:3.19
```

The cluster then pulls it under its upstream name, because containerd is what
rewrites the host:

```sh
kubectl run probe --image=docker.io/library/alpine:3.19 --rm -it --restart=Never -- echo ok
```

Note the `library/` prefix. A bare Docker Hub name like `alpine:3.19` resolves to
`docker.io/library/alpine`, so that is the path the mirror has to carry.

Adding an image needs no restart: containerd consults the mirror on every pull.
What is in there already:

```sh
curl -s http://localhost:5000/v2/_catalog
curl -s http://localhost:5000/v2/rancher/rancher/tags/list
```

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
same mirror by name and its agent reaches the management Rancher. It gets the
same `certs.d` tree, with no upstream fallback, and its own default route is
removed once it is up, so it is sealed exactly as the management cluster is.
`import` registers the cluster in Rancher, fetches the
registration manifest (reading the token from the Secret Rancher references, which
is where current Rancher keeps it), applies it to the downstream, and waits for
the cluster to report Active. `--import-instance e2e-<n>` names the downstream;
by default it is the first free one. Tear it down with `muster down --instance
e2e-<n>`.

## Teardown

`muster down` deletes the cluster and removes the network with it. The registry
is kept, because refilling it costs minutes and the next run reuses it as-is; add
`--airgap --registry <host> --insecure-registry` to remove that too. The registry
is detached from the network before the cluster is deleted, because a container
still on a network stops the runtime removing it, and a network that survives
teardown is silently reused by the next run.


For picking a channel by hand instead, see [Channels and versions](versions.md).
