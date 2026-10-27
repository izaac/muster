# Self-resolving the nightly matrix

Self-resolving sources cover every kind of row, so a job names only the line it
wants and never a channel:

| Row kind | Input | Resolves to |
|---|---|---|
| head | `--channel-source metadata --version v2.14-head` | the branch head, on whichever registry `branches-metadata.json` names |
| Prime | `--channel-source prime --version 2.14` | the newest Prime release of the line, from whichever Prime channel holds it; that line's newest head build when it has no release |
| Prime, in flight | `--channel-source prime-head --version 2.15` | the line's newest Prime head build, whether or not it has released |
| Prime GA | `--channel-source prime-ga --version v2.15` | the newest shipped Prime `X.Y.Z` in the GA channel; a full version pins exactly |
| Community GA | `--channel-source community-ga --version v2.15` | the newest shipped Community `X.Y.Z` |

`--repo` is ignored in all of them.

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

One resolution input per row kind. Add `--dry-run` to resolve and print only;
drop it to deploy. Every kind except `prime-head` resolves to the same build on a
re-run; `prime-head` is the in-flight one and says so.

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
muster up --dry-run --channel-source prime --version 2.15   # 2.15.3-alpha1
muster up --dry-run --channel-source prime --version 2.14   # 2.14.7-alpha1
muster up --dry-run --channel-source prime --version 2.13   # 2.13.11-alpha1
```

One command shape for every row. `--repo` is ignored, as in metadata mode.

Naming the channel by hand instead is wrong in every direction, and the
wrongness moves: a line with no rc yet is absent from `rancher-latest`, and
asking `rancher-alpha` for a line that has reached rc quietly installs an alpha.
Both flip as a line progresses, so a job that is correct today breaks or silently
downgrades later with nothing in it having changed.

All three Prime channels are asked, and the highest pick wins:

| Channel | URL |
|---|---|
| `rancher-prime-ga` | `charts.rancher.com/server-charts/prime` |
| `rancher-latest` | `charts.optimus.rancher.io/server-charts/latest` |
| `rancher-alpha` | `charts.optimus.rancher.io/server-charts/alpha` |

The GA channel is not optional. `charts.optimus.rancher.io` stopped receiving
final Prime releases at 2.14.3, so every newer GA lands only in
`charts.rancher.com/server-charts/prime`, and asking the pre-release channels
alone resolves "newest release" to a candidate for a version that already
shipped. `rancher-prime-ga` rather than `rancher-prime` is deliberate: both serve
the same charts, but the former resolves images to `registry.rancher.com`, which
answers an anonymous pull, while the latter uses the gated `registry.suse.com`.

The ordering is the release ladder, not the calendar: a final release outranks
its own rc, an rc outranks an alpha, and any of them outranks a hotfix build of
the same base. Ladder position is decided per version, so a *higher patch* still
wins across rungs: with 2.15.1 shipped and 2.15.2-alpha1 open, the alpha is what
`prime:2.15` resolves to. That is why `prime-ga` exists for post-release runs.

**Release first, head build only as a fallback.** The Prime channels also carry
commit-named head charts, and those are usually the freshest thing published for
a line:

| chart | published |
|---|---|
| `2.15.3-d95e99e-head` | 2026-10-27 |
| `2.15.2` | 2026-09-18 |

A Prime row with a release available picks the release anyway. A head chart is a
new identity on every commit, so a row resolving to one would deploy a different
build every run, which is the property a Prime row exists not to have. A release
stays put.

The exception is a minor that has no release at all. A minor ships Community
first, so it has Prime builds for months before its first Prime release; 2.16 has
dozens of Prime head charts and no release. Those rows take the newest head build
by publication date, because a commit sha carries no order, and revert to releases
by themselves the day the minor ships:

```sh
muster up --dry-run --channel-source prime --version 2.16
# 2.16.0-79f63a6-head in rancher-latest (HEAD BUILD, differs on the next run)
```

A head pick is not reproducible, which is why `prime:` only does it when it has
no release to take. Pin one build on the fixed path when a result has to be
repeatable:

```sh
muster up --dry-run --repo rancher-latest --version 2.16.0-79f63a6-head
```

### `prime-head`: the in-flight build of a minor

`prime:` falls back to a head build only when a minor has no release, which leaves
the common case unreachable: development resumes on a branch the moment a patch
ships, so every maintained minor has a head build ahead of its newest release.

| Line | `prime:` | `prime-head:` |
|---|---|---|
| 2.14 | `2.14.7-alpha1` | `2.14.7-c0732c6-head` |
| 2.15 | `2.15.3-alpha1` | `2.15.3-d95e99e-head` |
| 2.16 | `2.16.0-<sha>-head` | `2.16.0-<sha>-head` |

`prime-head:` skips the release pick and takes the head directly:

```sh
muster up --dry-run --channel-source prime-head --version 2.15
```

Use it to test what is in flight, before an rc opens. It is deliberately not
reproducible: the same row resolves to a different commit tomorrow, so a result
worth keeping has to record the resolved version rather than the row.

### `prime-ga` and `community-ga`: a shipped release

`prime:` walks the release ladder, so with 2.15.2 shipped it returns
2.15.3-alpha1 the day that patch opens, and a head build for a minor with no
release at all. That is right for the weekly rc and alpha pass and wrong for
verifying a release that has just gone out.

A GA row reads one edition's release channel and only final `X.Y.Z`, so the
answer always shipped. It also accepts a full version, which `prime:` does not,
so a run can pin the release it means to test:

```sh
muster up --dry-run --channel-source prime-ga --version v2.14       # 2.14.6
muster up --dry-run --channel-source community-ga --version v2.13   # 2.13.3
muster up --dry-run --channel-source prime-ga --version v2.14.6     # pinned exactly
```

| Kind | Channel read | URL |
|---|---|---|
| `prime-ga` | `rancher-prime-ga` | `charts.rancher.com/server-charts/prime` |
| `community-ga` | `rancher-com-rc` | `releases.rancher.com/server-charts/latest` |

The edition is part of the kind because the same version number is a different
build on each side: chart 2.14.6 deploys
`registry.rancher.com/rancher/rancher:v2.14.6` for Prime and
`rancher/rancher:v2.14.6` for Community, and those images have different digests.

A GA row does not set the image tag. A released chart names its own image in
`appVersion`, so the chart is asked for by version and the install omits
`rancherImageTag`, leaving the chart's value in place. `--dry-run` says
`(from chart appVersion)` on the image row when that happened. The resolver also
checks that `appVersion` agrees with the chart version (allowing for the leading
`v`), because a chart that numbered its image differently would otherwise pull a
tag that was never published and the pods would sit in `ImagePullBackOff`.

`community-ga:` is a fixed-channel row in every other respect, so it can also be
run by hand when the line is known to still publish Community releases.

**Line matching is anchored.** A `2.1` request never answers with `2.15`, and a
`2.12.5` request never answers with `2.12.50`; a version matches its line only at
a separator. That is what makes `--version 2.14` safe to put in a job.

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

Resolved live on 2026-10-26. The point of the table is the last column: a row's
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
| `--version 2.15` | `rancher-alpha` | `2.15.3-alpha1` | `stgregistry.suse.com/rancher/rancher:v2.15.3-alpha1` | prime |
| `--version 2.14` | `rancher-alpha` | `2.14.7-alpha1` | `stgregistry.suse.com/rancher/rancher:v2.14.7-alpha1` | prime |
| `--version 2.13` | `rancher-alpha` | `2.13.11-alpha1` | `stgregistry.suse.com/rancher/rancher:v2.13.11-alpha1` | prime |
| `--version 2.16` | `rancher-latest` | `2.16.0-79f63a6-head` | `stgregistry.suse.com/rancher/rancher:v2.16.0-79f63a6-head` | prime, head build |

2.13, 2.14 and 2.15 resolve to an alpha rather than the GA of the previous patch
because the next patch is open: 2.14.6 has shipped, and 2.14.7-alpha1 outranks it
on patch number. That is the release ladder doing its job for a pre-release pass.
Post-release verification wants `prime-ga` instead:

| Row | Channel | Chart | Image | Type |
|---|---|---|---|---|
| `prime-ga --version v2.15` | `rancher-prime-ga` | `2.15.2` | `registry.rancher.com/rancher/rancher:v2.15.2` | prime |
| `prime-ga --version v2.14` | `rancher-prime-ga` | `2.14.6` | `registry.rancher.com/rancher/rancher:v2.14.6` | prime |
| `community-ga --version v2.13` | `rancher-com-rc` | `2.13.3` | `rancher/rancher:v2.13.3` | community |

The 2.16 row is a head build that resolves differently on the next run by design.
`prime-head --version v2.15` takes `2.15.3-d95e99e-head` from `rancher-latest`,
which `prime:` never picks while a release exists.

Every Prime row reports the publication date of the release it picked, as a
`released` line in `--dry-run` and as `RANCHER_CHART_RELEASED`, so a job can drop
a row whose line has gone quiet without parsing output. `prime-ga` and
`community-ga` report it too, and the `image` row says `(from chart appVersion)`
because the chart, not muster, chose the tag.

### `community:` rows, and why they drop

| Row | Community chart | Newest Prime release | Community line |
|---|---|---|---|
| `v2.15-head` | `2.15.2` | `2.15.3-alpha1` | level, still alive |
| `v2.14-head` | `2.14.3` | `2.14.7-alpha1` | four patches behind, stopped |
| `v2.13-head` | `2.13.3` | `2.13.11-alpha1` | eight patches behind, stopped |

Compare them with `--repo rancher-com-rc` against `--channel-source prime` (or
`prime-ga` for the shipped patch alone) for the same line. The `-head` image keeps rebuilding on both registries after the
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
muster up --dry-run --channel-source prime-head --version v2.15
for v in v2.15 v2.14 v2.13; do
  muster up --dry-run --channel-source prime-ga --version "$v"
  muster up --dry-run --channel-source community-ga --version "$v"
done
```

`--prefer-staging` is a date/patch probe for ad-hoc use and is deliberately
**not** a CI input, because it is not reproducible day to day.

The UI a row serves follows the image, and for a head row that is not always the
branch: `--ui-offline auto` reconciles it after the pod starts and fails if the
setting never took. See [Dashboard UI and tests](dashboard.md#choosing-which-ui-is-served).

For fixed-channel selection and reading the flavour off an image, see
[Channels and versions](versions.md).
