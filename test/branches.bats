#!/usr/bin/env bats
# Unit tests for lib/branches.sh. The parser is pure, so the fixture below is a
# trimmed copy of rancher/dashboard branches-metadata.json: master and
# release-2.15 carry the full E2E block, release-2.14 carries only an image (as
# the real file does), and the image there has a registry prefix.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  . "$ROOT/lib/util.sh"
  # shellcheck source=../lib/buildui.sh
  . "$ROOT/lib/buildui.sh"
  # shellcheck source=../lib/branches.sh
  . "$ROOT/lib/branches.sh"

  FIXTURE="$(
    cat <<'JSON'
{
  "branches": {
    "master": {
      "milestone": {
        "version": "v2.16.0",
        "codeFreeze": false
      },
      "e2e": {
        "rancher-image": {
          "namespace": "rancher",
          "name": "rancher",
          "tag": "head"
        },
        "runtime-rancher-version": "2.15.0",
        "helm": {
          "repo-url": "https://charts.optimus.rancher.io/server-charts/release-2.15"
        },
        "kube": {
          "version": "v1.35.2+k3s1"
        }
      },
      "rancher-rancher-repo": {
        "branch": "main"
      }
    },
    "release-2.15": {
      "e2e": {
        "rancher-image": {
          "namespace": "rancher",
          "name": "rancher",
          "tag": "v2.15-head"
        },
        "kube": {
          "version": "v1.35.2+k3s1"
        }
      }
    },
    "release-2.14": {
      "e2e": {
        "rancher-image": {
          "registry": "stgregistry.suse.com",
          "namespace": "rancher",
          "name": "rancher",
          "tag": "v2.14-head"
        }
      }
    }
  }
}
JSON
  )"
}

# run cannot use `bash -c` here: a subshell would not have the sourced
# functions. A wrapper keeps the pipe in the current shell.
_parse() { printf '%s' "$FIXTURE" | branches_parse "$1"; }
_parse_junk() { printf 'not json at all\n' | branches_parse master; }

# --- branches_parse ----------------------------------------------------------

@test "branches_parse reads every E2E fact for a branch" {
  run _parse master
  [ "$status" -eq 0 ]
  [[ "$output" == *"KUBE_VERSION=v1.35.2+k3s1"* ]]
  [[ "$output" == *"RANCHER_IMAGE_TAG=head"* ]]
  [[ "$output" == *"RANCHER_IMAGE=rancher/rancher"* ]]
  [[ "$output" == *"HELM_REPO_URL=https://charts.optimus.rancher.io/server-charts/release-2.15"* ]]
}

@test "branches_parse keeps branches apart" {
  run _parse release-2.15
  [[ "$output" == *"RANCHER_IMAGE_TAG=v2.15-head"* ]]
  [[ "$output" != *"tag=head"* ]]
  [[ "$output" != *"HELM_REPO_URL"* ]]
}

@test "branches_parse prefixes the registry when the branch pins one" {
  run _parse release-2.14
  [[ "$output" == *"RANCHER_IMAGE=stgregistry.suse.com/rancher/rancher"* ]]
}

@test "branches_parse omits fields the branch does not carry" {
  run _parse release-2.14
  [[ "$output" != *"KUBE_VERSION"* ]]
  [[ "$output" != *"HELM_REPO_URL"* ]]
}

@test "branches_parse yields nothing for an unknown branch" {
  run _parse release-9.9
  [ "$output" = "" ]
}

@test "branches_parse ignores keys outside the E2E block" {
  run _parse master
  [[ "$output" != *"v2.16.0"* ]]
  [[ "$output" != *"main"* ]]
}

@test "branches_parse survives input that is not the expected JSON" {
  run _parse_junk
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

# --- branches_k3s_image ------------------------------------------------------

@test "branches_k3s_image maps a rancher tag to the k3s image for that line" {
  branches_fetch() { printf '%s' "$FIXTURE"; }
  [ "$(branches_k3s_image head)" = "rancher/k3s:v1.35.2+k3s1" ]
  [ "$(branches_k3s_image v2.15-head)" = "rancher/k3s:v1.35.2+k3s1" ]
}

@test "branches_k3s_image yields nothing when the branch has no kube version" {
  branches_fetch() { printf '%s' "$FIXTURE"; }
  [ "$(branches_k3s_image v2.14-head)" = "" ]
}

@test "branches_k3s_image yields nothing for a tag that maps to no branch" {
  branches_fetch() { printf '%s' "$FIXTURE"; }
  [ "$(branches_k3s_image garbage)" = "" ]
}

# --- branches_apply_k3s_image ------------------------------------------------
# Nothing here may break a run: an unreachable file leaves the driver default.

@test "an unpinned K3S_IMAGE is filled in from the metadata" {
  branches_fetch() { printf '%s' "$FIXTURE"; }
  unset K3S_IMAGE
  RANCHER_IMAGE_TAG=v2.15-head branches_apply_k3s_image
  [ "$K3S_IMAGE" = "rancher/k3s:v1.35.2+k3s1" ]
}

@test "an explicit K3S_IMAGE always wins" {
  branches_fetch() { printf '%s' "$FIXTURE"; }
  K3S_IMAGE=rancher/k3s:v1.33.1-k3s1
  RANCHER_IMAGE_TAG=v2.15-head branches_apply_k3s_image
  [ "$K3S_IMAGE" = "rancher/k3s:v1.33.1-k3s1" ]
}

@test "MUSTER_IGNORE_BRANCH_METADATA opts out entirely" {
  branches_fetch() { printf '%s' "$FIXTURE"; }
  unset K3S_IMAGE
  MUSTER_IGNORE_BRANCH_METADATA=1 RANCHER_IMAGE_TAG=v2.15-head branches_apply_k3s_image
  [ -z "${K3S_IMAGE:-}" ]
}

@test "an unreachable metadata file leaves the driver default in place" {
  branches_fetch() { return 0; }
  unset K3S_IMAGE
  run branches_apply_k3s_image
  [ "$status" -eq 0 ]
  [ -z "${K3S_IMAGE:-}" ]
}
