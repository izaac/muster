# Self-resolving the nightly matrix

Two self-resolving modes cover the two kinds of row, so a job names only the
line it wants and never a channel:

| Row kind | Input | Resolves to |
|---|---|---|
| head | `--channel-source metadata --version v2.14-head` | the branch head, on whichever registry `branches-metadata.json` names |
| Prime | `--channel-source prime --version 2.14` | the newest Prime release of the line, from whichever Prime channel holds it |

`--repo` is ignored in both.

`--channel-source metadata` makes muster pick the channel and image itself,
instead of taking a fixed `--repo`. It reads the branch named by `--version` from
the dashboard team's
[`branches-metadata.json`](https://github.com/rancher/dashboard/blob/master/branches-metadata.json)
and resolves everything from there:

- the `registry` key decides Prime vs Community, so the image is the branch head
  on whichever registry that line currently publishes to,
- the image keeps the branch head tag (`v2.14-head`), not a chart version,
- the chart comes from the branch head channel (the `helm.repo-url` key, else the
  optimus `server-charts/<branch>` channel),
- the k3s version comes from the same file.

```sh
# Whatever the nightly should run for the 2.14 line, resolved from the file
muster up --dry-run --channel-source metadata --version v2.14-head
```

This exists because the alternative, choosing Prime or Community by probing
registries or build dates, gets it wrong: `release-2.14` has moved between
registries repeatedly by human decision, and a fresh build on one side does not
mean that side is the one under test. The file is the record of that decision, is
already maintained through PR review, and already gates the dashboard merge, so
muster reads it rather than guessing. `--repo` is ignored in this mode.

Which build each row resolves to still follows the file: on a day when the 2.13
`registry` key points at staging, `--version v2.13-head` resolves to the
`stgregistry.suse.com` head rather than the frozen Docker Hub one; when the key
flips, muster follows with no change here. Read the flavour off the result with
`--dry-run`, the same as any other run.

## CI usage: the head rows and the Prime rows

Two reproducible resolution inputs, one per row kind. Add `--dry-run` to resolve
and print only; drop it to deploy.

The nightly **head** rows read the file, so the same call resolves the same way
until the file changes:

```sh
muster up --dry-run --channel-source metadata --version head
muster up --dry-run --channel-source metadata --version v2.15-head
muster up --dry-run --channel-source metadata --version v2.14-head
muster up --dry-run --channel-source metadata --version v2.13-head
```

The **Prime** rows take the newest Prime release of a line. Which channel holds
that changes as a line progresses, so name the line and let muster find it:

```sh
muster up --dry-run --channel-source prime --version 2.14   # 2.14.4-rc1     (rancher-latest)
muster up --dry-run --channel-source prime --version 2.13   # 2.13.8-rc1     (rancher-latest)
muster up --dry-run --channel-source prime --version 2.15   # 2.15.1-alpha1  (rancher-alpha)
```

One command shape for every row. `--repo` is ignored, as in metadata mode.

Naming the channel by hand instead is wrong in both directions, and the wrongness
moves: `--repo rancher-latest --version 2.15` fails today because that line has
no rc yet, and `--repo rancher-alpha --version 2.14` quietly installs an alpha
when an rc exists. Both flip as a line progresses, so a job that is correct today
breaks or silently downgrades later with nothing in it having changed.

**Release, not most recent.** `rancher-latest` also carries commit-named head
charts, and for 2.15 those are the freshest thing published:

| channel | newest 2.15 chart | published |
|---|---|---|
| `rancher-latest` | `2.15.1-6455c9ca...-head` | 2026-08-14 |
| `rancher-alpha` | `2.15.1-alpha1` | 2026-08-05 |

`prime:` picks the alpha anyway. A head chart is a new identity on every commit,
so a row resolving to one would deploy a different build every run, which is the
property a Prime row exists not to have. An alpha stays put until the next alpha.
Both are Prime builds; the difference is release versus rolling. To run a head
build deliberately, pin one: `--repo rancher-latest --version <the exact chart>`.

The ordering is the release ladder, not the calendar: a final release outranks
its own rc, and an rc outranks an alpha.

A line that has not released at all has no Prime row yet. muster says which
charts it does carry, so the choice is visible rather than a dead end:

```
$ muster up --dry-run --channel-source prime --version 2.16
[muster] ERROR the 2.16 line is in rancher-latest but has no release yet;
         its newest head charts are: 2.16.0-9a46e2a-head 2.16.0-23449b8-head ...
[muster] ERROR a Prime row takes a release, so pin a head chart on purpose:
         --repo rancher-latest --version <one of the above>
```

A `metadata:` head row deploys from whichever registry the key names, and it
still reports Community, so `RancherPrime` must not be asserted on it. The
reason is narrower than "head builds are Community", because two different tags
are both called a head build:

| Tag | Where it is published | Reports |
|---|---|---|
| `vX.Y-head` (branch head, rolling) | Docker Hub, and the staging registry while that line publishes there | `community` |
| `vX.Y.Z-<sha>-head` (one commit) | staging registry only | `prime` |

The matrix rows use the first: `branches-metadata.json` pins `v2.14-head`, so a
`metadata:` row is a Community-type build wherever it is served from. The second
is what `rancher-latest` head charts point at, and it is Prime, which is why
pinning one of those charts is a way to run a Prime head build.

`--prefer-staging` is a date/patch probe for ad-hoc use and is deliberately
**not** a CI input, because it is not reproducible day to day.

For fixed-channel selection and reading the flavour off an image, see
[Channels and versions](versions.md).
