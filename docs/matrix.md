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
- the chart comes from the release line the image is built for, which the image
  states in `CATTLE_CHART_DEFAULT_BRANCH`, falling back to the `helm.repo-url`
  key and then to the optimus `server-charts/<branch>` channel,
- the k3s version comes from the same file.

muster reads the file but owns the decision, and the chart line is where that
matters. The two namespaces cannot line up: a chart channel is always
`release-X.Y` while the dashboard's top branch is called `master`, so there is no
`server-charts/master` and the key for master has to point at some other line. It
currently names `release-2.15` while `rancher/rancher:head` is `dev-v2.16`.
Taking the line from the image resolves that without an upstream change, and it
keeps holding when 2.17 opens and master moves up. Set
`MUSTER_CHART_LINE=metadata` to follow the key unconditionally, which is how to
reproduce what the dashboard's own CI deploys.

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
muster up --dry-run --channel-source prime --version 2.15   # 2.15.1-rc2
muster up --dry-run --channel-source prime --version 2.14   # 2.14.5-rc2
muster up --dry-run --channel-source prime --version 2.13   # 2.13.9-rc2
```

One command shape for every row. `--repo` is ignored, as in metadata mode.

Naming the channel by hand instead is wrong in both directions, and the wrongness
moves: a line with no rc yet is absent from `rancher-latest`, and asking
`rancher-alpha` for a line that has reached rc quietly installs an alpha. Both
flip as a line progresses, so a job that is correct today breaks or silently
downgrades later with nothing in it having changed. The release team is also
consolidating the Prime pre-release charts into a single channel, which moves the
answer again; a row that names the line rather than the channel is unaffected.

**Release, not most recent.** The Prime channels also carry commit-named head
charts, and those are usually the freshest thing published for a line:

| chart | published |
|---|---|
| `2.15.2-a90f264-head` | 2026-09-01 |
| `2.15.1-rc2` | 2026-08-25 |

A Prime row picks the rc anyway. A head chart is a new identity on every commit,
so a row resolving to one would deploy a different build every run, which is the
property a Prime row exists not to have. A release stays put. Both are Prime
builds; the difference is release versus rolling. To run a head build
deliberately, pin one: `--repo rancher-latest --version <the exact chart>`.

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

A `metadata:` head row deploys from whichever registry the key names. Whether it
reports Prime is a property of the build, and it is about to change: the release
team is moving the floating `vX.Y-head` tags onto Prime builds from 11 September
2026, starting with the lines that are Prime-only. Two different tags are both
called a head build, and today only one of them is Prime:

| Tag | Where it is published | Reports today |
|---|---|---|
| `vX.Y-head` (branch head, rolling) | Docker Hub, and the staging registry while that line publishes there | `community`, becoming `prime` per line |
| `vX.Y.Z-<sha>-head` (one commit) | staging registry only | `prime` |

So a `metadata:` row must not assert either value from the tag shape. muster
reads it off the image config rather than inferring it, which is what makes the
answer follow the flip without a change here:

```sh
muster up --dry-run --channel-source metadata --version v2.14-head   # prints flavour
```

Assert what `--dry-run` reports, or drop the assertion for `metadata:` rows and
keep it on the `prime:` and `community:` rows, whose channel fixes the answer.

## What every row resolves to

Resolved live on 2026-09-01. The point of the table is the last column: a row's
build type is a property of the image, and two of these are about to change.

### Nightly: the `metadata:` rows

| Row | Chart channel | Chart | Image | Type |
|---|---|---|---|---|
| `--version head` | `release-2.16` | `2.16-9a46e2a-head` | `rancher/rancher:head` | community |
| `--version v2.15-head` | `release-2.15` | `2.15-842907d3-head` | `rancher/rancher:v2.15-head` | community |
| `--version v2.14-head` | `release-2.14` | `2.14-79ae9996-head` | `stgregistry.suse.com/rancher/rancher:v2.14-head` | community |
| `--version v2.13-head` | `release-2.13` | `2.13-f4481ab3-head` | `stgregistry.suse.com/rancher/rancher:v2.13-head` | community |

2.14 and 2.13 already deploy from the Prime registry, and the build served there
is still Community-type. From 11 September the floating `v2.13-head` and
`v2.14-head` tags move onto Prime builds, so those two rows become `prime` while
2.15 and master stay `community`. The row does not change; only the answer does.

The master row is the one place muster overrides the file. `helm.repo-url` points
master at `release-2.15` while `rancher/rancher:head` is built from `dev-v2.16`,
so the chart line is taken from the image instead. Without that the run gets a
2.15 chart, which has no `rancher-charts-copy` initContainer, and a 2.16 server
with no system charts.

### Weekly: the `prime:` rows

| Row | Channel | Chart | Image | Type |
|---|---|---|---|---|
| `--version 2.15` | `rancher-latest` | `2.15.1-rc2` | `stgregistry.suse.com/rancher/rancher:v2.15.1-rc2` | prime |
| `--version 2.14` | `rancher-latest` | `2.14.5-rc2` | `stgregistry.suse.com/rancher/rancher:v2.14.5-rc2` | prime |
| `--version 2.13` | `rancher-latest` | `2.13.9-rc2` | `stgregistry.suse.com/rancher/rancher:v2.13.9-rc2` | prime |
| `--version 2.16` | none | none | none | no release; covered by `metadata:head` |

Every Prime row reports the publication date of the release it picked, as a
`released` line in `--dry-run` and as `RANCHER_CHART_RELEASED`, so a job can drop
a row whose line has gone quiet without parsing output.

### `community:` rows, and why they drop

| Row | Community chart | Newest Prime release | Community line |
|---|---|---|---|
| `v2.15-head` | `2.15.1` | `2.15.1-rc2` | level, still alive |
| `v2.14-head` | `2.14.3` | `2.14.5-rc2` | two patches behind, stopped |
| `v2.13-head` | `2.13.3` | `2.13.9-rc2` | six patches behind, stopped |

Compare them with `--repo rancher-com-rc` against `--channel-source prime` for
the same line. The `-head` image keeps rebuilding on both registries after the
release line stops, so its build date proves nothing; the patch gap is the
signal. Community head builds are also being disabled for the Prime-only lines,
at which point these rows drop themselves on a missing image.

Regenerate the whole table with:

```sh
for v in head v2.15-head v2.14-head v2.13-head; do
  muster up --dry-run --channel-source metadata --version "$v"
done
for v in 2.16 2.15 2.14 2.13; do
  muster up --dry-run --channel-source prime --version "$v"
done
```

`--prefer-staging` is a date/patch probe for ad-hoc use and is deliberately
**not** a CI input, because it is not reproducible day to day.

For fixed-channel selection and reading the flavour off an image, see
[Channels and versions](versions.md).
