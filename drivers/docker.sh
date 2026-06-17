#!/usr/bin/env bash
# drivers/docker.sh - plain-docker substrate. Deferred past v1; k3d is the
# strategic substrate. The stub stays honest and fails with a clear message.

[ -n "${_MUSTER_DRIVER_DOCKER_SH:-}" ] && return 0
_MUSTER_DRIVER_DOCKER_SH=1

driver_up() { die "docker driver is not implemented; use --provider k3d or existing"; }
driver_down() { die "docker driver is not implemented; use --provider k3d or existing"; }
driver_kubeconfig() { die "docker driver is not implemented; use --provider k3d or existing"; }
driver_endpoint() { die "docker driver is not implemented; use --provider k3d or existing"; }
