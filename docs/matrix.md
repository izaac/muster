# Self-resolving the nightly matrix

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

The **Prime** rows name the channel explicitly and take the newest release of the
line (a bare minor). rc (`rancher-latest`) is preferred; a line with no rc yet
uses alpha (`rancher-alpha`):

```sh
muster up --dry-run --repo rancher-latest --version 2.14   # newest rc:    v2.14.4-rc1
muster up --dry-run --repo rancher-latest --version 2.13   # newest rc:    v2.13.8-rc1
muster up --dry-run --repo rancher-alpha  --version 2.15   # newest alpha: v2.15.1-alpha1
```

A `metadata:` head row deploys from whichever registry the key names, but a
`-head` build is community-type even on the Prime registry; only the rc/alpha
Prime rows report `RancherPrime`. `--prefer-staging` is a date/patch probe for
ad-hoc use and is deliberately **not** a CI input, because it is not reproducible
day to day.

For fixed-channel selection and reading the flavour off an image, see
[Channels and versions](versions.md).
