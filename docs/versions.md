# Channels and versions

How muster picks the chart, the image, and the Kubernetes version, and how to
check what a set of flags resolves to before running it.

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

`rancher-latest` publishes a chart for each head build, named after the commit
(`2.16.0-<sha>-head`), so a head can be resolved the same way as any other
version, chart and image together:

```sh
# Newest Prime head: master today, since 2.16.0 is master's milestone
muster up --provider k3d --repo rancher-latest --version head
```

```
  chart version    2.16.0-ff28ae6aea8dcb820bcc2ff8bfd1bc45d4e2ee65-head
  image            stgregistry.suse.com/rancher/rancher:v2.16.0-...-head
  flavour          prime  (Prime-only UI extensions will load)
```

Because those charts are commit-named, `--version head` follows whatever was
built last, which is what makes it unsuitable as a CI input. Pin one to get a
reproducible run; a version naming one published chart is matched exactly, so no
channel filter applies:

```sh
muster up --provider k3d --repo rancher-latest \
  --version 2.15.1-c7913dce4e586d7b87cf73bbf6443d953bd184f7-head
```

The available ones are in the channel listing:

```sh
helm search repo rancher-latest/rancher --devel --versions --max-col-width=0 \
  | grep -- '-head'
```

`rancher-alpha` carries no head charts, only alphas. On that channel
`--version head` resolves the newest alpha rather than a head build, and
`--image-tag` is the way to run a head server against it:

```sh
# Newest Prime alpha chart, running a release-2.15 head build
muster up --provider k3d --repo rancher-alpha --version head \
  --image-tag v2.15.1-965e1896835ebcb961689a35f4bfe34e43ce2a4d-head
```

On the staging registry a head build is only ever published under its commit
name. There is no `v2.16-head`, and no plain `head`, so reading a flavour off
one of those looks like this:

```sh
$ skopeo inspect --config docker://stgregistry.suse.com/rancher/rancher:v2.16-head \
    | grep -o 'RANCHER_VERSION_TYPE=[a-z]*'
$
```

Nothing comes back, which is easy to read as `RANCHER_VERSION_TYPE=` and
conclude the build is Community. It is not a Community build; there is no build.
Every commit-named 2.16 head on that registry reports `prime`. This is why
`--dry-run` distinguishes `missing` from `community` rather than collapsing both
into "not Prime": use it instead of grepping the image by hand.

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

### When a line has no release candidate yet

`rancher-latest` selects release candidates and `rancher-alpha` selects alphas,
so a bare minor means "the newest rc (or alpha) of that line". A line that is
published but has not reached that stage resolves to nothing, and muster says
which shapes it does carry rather than only that nothing matched:

```
$ muster up --dry-run --repo rancher-latest --version 2.15
[muster] ERROR the 2.15 line is in rancher-latest but has no -rc chart yet;
         it carries: 2.15.1-30739f3e...-head 2.15.1-ac63bee9...-head
[muster] ERROR for a 2.15 pre-release try --repo rancher-alpha --version 2.15,
         or pin one of the above with --version
[muster] ERROR no chart version in rancher-latest matches '2.15'
```

The filter is deliberate: if a bare minor fell back to a head build, a pinned CI
input would quietly change from a fixed release candidate to a rolling one.

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
  ui               the image  (a release build serves what it embeds)
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

For the nightly matrix, which resolves the channel and image on its own instead
of taking a fixed `--repo`, see [Self-resolving the nightly matrix](matrix.md).

For a Prime run behind a mirror, see [Airgapped installs](airgap.md).
