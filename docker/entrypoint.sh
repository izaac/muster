#!/usr/bin/env bash
# docker/entrypoint.sh - grant Docker socket access, then drop to non-root.
#
# muster drives the host Docker daemon over a bind-mounted socket to create
# sibling containers (k3d). The socket's owning GID differs by platform: a
# numbered docker group on Linux, root (0) on Docker Desktop for macOS and
# Windows. To stay non-root while remaining portable, this entrypoint starts
# as root only long enough to add the muster user to the socket's group, then
# uses gosu to exec the command as the unprivileged muster user.
#
# If the container is already running as non-root (the user supplied --user),
# we skip the privileged step and just exec, honouring their choice.
set -euo pipefail

SOCK="${DOCKER_HOST_SOCK:-/var/run/docker.sock}"
TARGET_USER="muster"

if [ "$(id -u)" -eq 0 ]; then
  if [ -S "$SOCK" ]; then
    sock_gid="$(stat -c '%g' "$SOCK")"
    if [ "$sock_gid" -eq 0 ]; then
      # Docker Desktop: socket is root:root. Add muster to the root group so it
      # can reach the socket without the container itself running as root.
      usermod -aG root "$TARGET_USER"
    else
      # Linux: ensure a group with the socket's GID exists and add muster to it.
      if ! getent group "$sock_gid" >/dev/null; then
        groupadd --gid "$sock_gid" docker-host
      fi
      usermod -aG "$(getent group "$sock_gid" | cut -d: -f1)" "$TARGET_USER"
    fi
  fi
  # HOME is reset because we changed groups; keep muster's cache writable.
  exec gosu "$TARGET_USER" "$@"
fi

# Already unprivileged (user passed --user): run as-is.
exec "$@"
