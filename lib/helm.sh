#!/usr/bin/env bash
# lib/helm.sh - Rancher chart line + image resolution and install.
# Ported in Phase 1 from the ansible resolve-helm-version task and the
# configure_rancher_helm logic in k3d-rancher.sh.

[ -n "${_MUSTER_HELM_SH:-}" ] && return 0
_MUSTER_HELM_SH=1

# helm_resolve_version - map a release line (head|prime|latest|alpha|<pin>) to a
# concrete chart repo URL, chart version, and image tag.
helm_resolve_version() { die "helm_resolve_version: not implemented (Phase 1)"; }

# helm_install_rancher - add the repo and install cert-manager + rancher.
helm_install_rancher() { die "helm_install_rancher: not implemented (Phase 1)"; }
