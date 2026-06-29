#!/usr/bin/env bash
# lib/util.sh - shared primitives for muster.
#
# Pure-ish helpers with no provider or framework knowledge: logging, strict-mode
# wiring, value coercion, retries, CA-bundle discovery, and command guards.
# Source this first from the entrypoint; every other lib may assume it is loaded.

# Guard against double-sourcing (libs source each other freely).
[ -n "${_MUSTER_UTIL_SH:-}" ] && return 0
_MUSTER_UTIL_SH=1

# --- logging -----------------------------------------------------------------
# All diagnostics go to stderr so stdout stays reserved for machine-readable
# output (endpoints, handoff env, kubeconfig paths) that callers capture.

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  _C_DIM=$'\033[2m'
  _C_RED=$'\033[31m'
  _C_YEL=$'\033[33m'
  _C_GRN=$'\033[32m'
  _C_RST=$'\033[0m'
else
  _C_DIM='' _C_RED='' _C_YEL='' _C_GRN='' _C_RST=''
fi

log_info() { printf '%s[muster]%s %s\n' "$_C_DIM" "$_C_RST" "$*" >&2; }
log_ok() { printf '%s[muster]%s %s%s%s\n' "$_C_DIM" "$_C_RST" "$_C_GRN" "$*" "$_C_RST" >&2; }
log_warn() { printf '%s[muster] WARN%s %s\n' "$_C_YEL" "$_C_RST" "$*" >&2; }
log_err() { printf '%s[muster] ERROR%s %s\n' "$_C_RED" "$_C_RST" "$*" >&2; }

# die <message...> - log an error and exit non-zero.
die() {
  log_err "$*"
  exit 1
}

# --- strict mode -------------------------------------------------------------

# install_err_trap - report the failing command and line on any ERR, so a
# `set -e` abort is never silent. Call once from the entrypoint after set -E.
_on_err() {
  local rc=$? line=${1:-?}
  log_err "aborted (exit $rc) at line $line: ${BASH_COMMAND}"
  exit "$rc"
}
install_err_trap() {
  set -Eeuo pipefail
  trap '_on_err "$LINENO"' ERR
}

# --- value coercion ----------------------------------------------------------

# is_true <value> - true for 1/true/yes/on (case-insensitive, surrounding
# whitespace ignored); false for everything else, including empty/unset. The
# accepted set is exactly these four spellings: "y", "t", "enable", "2", etc.
# are deliberately NOT truthy, so config typos fail closed rather than silently
# enabling a mode.
is_true() {
  local v
  v="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$v" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# --- command guards ----------------------------------------------------------

# require_cmd <name> [hint] - die with a clear message if a binary is absent.
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1${2:+ ($2)}"
}

# --- container runtime -------------------------------------------------------

# podman_docker_sock - echo the podman socket path when the active Docker
# endpoint (DOCKER_HOST) is a podman socket, else echo nothing. Matches both
# rootful (/run/podman/podman.sock) and rootless
# (/run/user/<uid>/podman/podman.sock) sockets.
#
# k3d bind-mounts the Docker socket into its tools/node containers and defaults
# to /var/run/docker.sock, which does not exist on a podman-only host, so k3d
# needs DOCKER_SOCK pointed at the real podman socket regardless of mode.
podman_docker_sock() {
  local sock=""
  case "${DOCKER_HOST:-}" in
    *podman*) sock="${DOCKER_HOST#unix://}" ;;
  esac
  if [ -n "$sock" ] && [ -S "$sock" ]; then
    printf '%s' "$sock"
  fi
  return 0
}

# is_rootless_podman_sock <sock> - true when the given podman socket is a
# rootless one (lives under the per-user runtime dir). Only rootless k3s needs
# feature-gates=KubeletInUserNamespace=true; rootful podman (and real Docker,
# including CI) runs the kubelet in the initial user namespace where that gate
# must NOT be set.
is_rootless_podman_sock() {
  local sock="$1"
  case "$sock" in
    "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"/* | /run/user/*) return 0 ;;
    *) return 1 ;;
  esac
}

# container_cli <args...> - run a container-runtime CLI command against the
# daemon muster is actually driving.
#
# k3d is a Docker API client and honours DOCKER_HOST, so it talks to whichever
# daemon DOCKER_HOST points at. On a podman host the `docker` CLI is a podman
# shim that honours CONTAINER_HOST, NOT DOCKER_HOST, so a plain `docker inspect`
# silently queries a different (usually rootless) daemon than the one k3d built
# the cluster on. Route through `podman --url <sock>` when a podman socket is in
# play so CLI queries land on the same daemon as k3d. On real Docker (CI) there
# is no podman socket and no podman binary, so fall back to plain `docker`.
container_cli() {
  local sock
  sock="$(podman_docker_sock)"
  if [ -n "$sock" ] && command -v podman >/dev/null 2>&1; then
    podman --url "unix://$sock" "$@"
  else
    docker "$@"
  fi
}

# is_podman_cli - true when the `docker` command is really a Podman shim (the
# binary resolves to podman, or `docker --version` reports Podman). A host with
# genuine Docker returns false. Used to keep socket resolution off real Docker.
is_podman_cli() {
  command -v docker >/dev/null 2>&1 || return 1
  local real
  real="$(readlink -f "$(command -v docker)" 2>/dev/null || true)"
  case "$real" in
    *podman*) return 0 ;;
  esac
  docker --version 2>/dev/null | grep -qi podman
}

# is_podman_host - true when muster is driving Podman rather than real Docker,
# detected either through the `docker` shim or a podman socket already in
# DOCKER_HOST. Real Docker hosts (no shim, non-podman DOCKER_HOST) return false.
is_podman_host() {
  is_podman_cli && return 0
  case "${DOCKER_HOST:-}" in
    *podman*) return 0 ;;
  esac
  return 1
}

# resolve_docker_host - on a Podman host, point DOCKER_HOST at the rootful socket
# so k3d, and Rancher's jailer (which creates device nodes a rootless user
# namespace cannot), talk to the privileged daemon. Both a per-user (rootless)
# and a system (rootful) socket commonly exist, and the default DOCKER_HOST often
# points at the unusable rootless one. Cases:
#   - DOCKER_HOST unset      -> adopt the rootful socket.
#   - DOCKER_HOST rootless    -> override to rootful (rootless cannot run Rancher).
#   - anything else (explicit rootful, real Docker, tcp://) -> left untouched.
# No-op on real Docker hosts, so the Docker path is never altered. Dies when a
# Podman host has no rootful socket enabled. MUSTER_ROOTFUL_SOCK overrides the
# rootful socket path (default /run/podman/podman.sock).
resolve_docker_host() {
  is_podman_host || return 0
  case "${DOCKER_HOST:-}" in
    "") : ;;
    *run/user/*)
      log_info "podman rootless socket in DOCKER_HOST; switching to rootful (Rancher's jailer needs root)"
      ;;
    *) return 0 ;;
  esac
  local rootful="${MUSTER_ROOTFUL_SOCK:-/run/podman/podman.sock}"
  if [ -S "$rootful" ]; then
    export DOCKER_HOST="unix://$rootful"
    log_info "podman: using rootful socket $DOCKER_HOST"
  else
    die "podman host needs the rootful socket. Enable it (e.g. sudo systemctl enable --now podman.socket) or set DOCKER_HOST to a usable endpoint."
  fi
}

# --- retries -----------------------------------------------------------------

# retry <attempts> <sleep_s> <description> [--] <command...>
# Run a command until it succeeds, swallowing its output between attempts.
retry() {
  local attempts="$1" sleep_s="$2" desc="$3" i
  shift 3
  [ "${1:-}" = "--" ] && shift
  for ((i = 1; i <= attempts; i++)); do
    if "$@" >/dev/null 2>&1; then
      log_ok "ready: $desc (attempt $i/$attempts)"
      return 0
    fi
    sleep "$sleep_s"
  done
  die "$desc not ready after $attempts attempts"
}

# --- TLS ---------------------------------------------------------------------

# ca_bundle - print a usable CA bundle path for HTTPS downloads, or nothing if
# none is found (callers then fall back to the tool's built-in default). Honours
# an already-exported bundle first, then Nix, then common system locations.
ca_bundle() {
  local c
  for c in \
    "${SSL_CERT_FILE:-}" \
    "${CURL_CA_BUNDLE:-}" \
    "${NIX_SSL_CERT_FILE:-}" \
    /etc/ssl/certs/ca-certificates.crt \
    /etc/ssl/certs/ca-bundle.crt \
    /etc/pki/tls/certs/ca-bundle.crt; do
    if [ -n "$c" ] && [ -r "$c" ]; then
      echo "$c"
      return 0
    fi
  done
}
