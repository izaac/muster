#!/usr/bin/env bash
# drivers/docker.sh - standalone docker container substrate.
#
# Rancher runs as a single privileged docker container (the pre-k3d install
# form), not a helm release on k8s. This driver therefore opts out of the
# core's helm-install path by declaring driver_installs_rancher (returns 0):
# cmd_up skips helm_resolve_version + helm_install_rancher and lets the
# container BE rancher. It also provides driver_gate (HTTP-only readiness),
# since there is no in-cluster rollout, webhook pod, or capi service to watch.
#
# Driver contract (4 verbs) plus optional hooks consumed by the core:
#   driver_up                 start the rancher container (reuse if running).
#   driver_down               remove the container + its network.
#   driver_kubeconfig         none; standalone rancher exposes no consumer
#                             kubeconfig. Prints empty so handoff omits it.
#   driver_endpoint           <host>:<port> the dashboard is served on.
#   driver_installs_rancher   returns 0: the container IS rancher (skip helm).
#   driver_resolve_image      print <image>:<tag> for the standalone container.
#   driver_gate               HTTP-only readiness gates (no kubectl).
#
# Image resolution reuses lib/helm.sh's channel map (repo_image) and tag rules
# (resolve_image_tag) so the version matrix is identical to k3d. Community
# channels (empty image) take the literal tag and need NO helm. Staging/prime
# channels pin a registry image whose tag is v<chart_version>; resolving that
# still needs helm search, so those channels require helm for the tag only
# (never for an install).

[ -n "${_MUSTER_DRIVER_DOCKER_SH:-}" ] && return 0
_MUSTER_DRIVER_DOCKER_SH=1

# Instance index drives host-port offsets so sharded instances do not collide,
# mirroring drivers/k3d.sh: e2e -> 0, e2e-1 -> 1, e2e-2 -> 2.
docker_index() {
  case "$INSTANCE" in
    e2e) echo 0 ;;
    e2e-[0-9]) echo "${INSTANCE##*-}" ;;
    *) die "instance must be 'e2e' or 'e2e-<n>' (got '$INSTANCE')" ;;
  esac
}

docker_container_name() { echo "muster-docker-${INSTANCE}"; }
docker_network() { echo "muster-docker-${INSTANCE}"; }
docker_https_port() { echo $(($(docker_index) + 8443)); }
docker_http_port() { echo $(($(docker_index) + 8080)); }

# in_container - true when muster itself runs inside a container. A
# containerised run drives the host Docker daemon and creates a sibling rancher
# container; the two share a docker network so the endpoint resolves to the
# rancher container name (no host port publish needed).
in_container() { [ -f /.dockerenv ]; }

# driver_installs_rancher - the container IS rancher, so the core must NOT run
# helm_install_rancher. See muster cmd_up.
driver_installs_rancher() { return 0; }

# driver_resolve_image - print <image>:<tag> for `docker run`. Community
# channels use the literal tag (helm-free); staging/prime use v<chart_version>,
# resolved via helm_resolve_version when not already exported.
driver_resolve_image() {
  local repo="${RANCHER_REPO:?RANCHER_REPO is required}" tag="${RANCHER_IMAGE_TAG:?RANCHER_IMAGE_TAG is required}"
  repo_valid "$repo" || die "unknown RANCHER_REPO '$repo' (valid: $(repo_keys))"
  local pinned image
  pinned="$(repo_image "$repo")"
  image="${pinned:-rancher/rancher}"
  if [ -z "$pinned" ]; then
    printf '%s:%s' "$image" "$tag"
  else
    require_cmd helm "staging/prime channels need helm to resolve the image tag"
    [ -n "${RANCHER_CHART_VERSION:-}" ] || helm_resolve_version
    printf '%s:%s' "$image" "${RANCHER_IMAGE_TAG_RESOLVED:?}"
  fi
}

driver_kubeconfig() { printf ''; }

driver_endpoint() {
  if [ -n "${EXTERNAL_HOSTNAME:-}" ]; then
    printf '%s' "$EXTERNAL_HOSTNAME"
  elif in_container; then
    printf '%s:443' "$(docker_container_name)"
  else
    printf 'localhost:%s' "$(docker_https_port)"
  fi
}

# driver_tunnel_port - the local port cloudflared's quick tunnel points at.
# cloudflared runs on the host and reaches the rancher container through the
# published https port, so this mirrors k3d. (External + in_container is a
# known gap: tunnel_up hardcodes localhost, so the muster container would need
# the rancher port published too. Host-shell external mode is the supported
# path, matching k3d.)
driver_tunnel_port() {
  docker_https_port
}

driver_up() {
  require_cmd docker "install docker"
  local name image
  name="$(docker_container_name)"
  image="$(driver_resolve_image)"

  if docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null | grep -qx true; then
    log_info "docker container '$name' already running, reusing it"
    return 0
  fi
  docker rm -f "$name" >/dev/null 2>&1 || true

  local run_args=(
    run -d --name "$name"
    --privileged --restart unless-stopped
    -e "CATTLE_BOOTSTRAP_PASSWORD=${RANCHER_PASSWORD:-password1234}"
  )
  if in_container; then
    docker network create "$(docker_network)" >/dev/null 2>&1 || true
    run_args+=(--network "$(docker_network)")
  else
    run_args+=(-p "$(docker_https_port):443" -p "$(docker_http_port):80")
  fi
  if [ -n "${DASHBOARD_DIST:-}" ]; then
    [ -d "$DASHBOARD_DIST" ] || die "--dashboard-dist '$DASHBOARD_DIST' is not a directory"
    run_args+=(
      -v "${DASHBOARD_DIST}:/usr/share/rancher/ui-dashboard/dashboard:ro"
      -e CATTLE_UI_OFFLINE_PREFERRED=true
    )
  fi
  run_args+=("$image")

  log_info "docker: starting $image as $name"
  docker "${run_args[@]}" >/dev/null

  if in_container; then
    docker network connect "$(docker_network)" "$(cat /etc/hostname)" 2>/dev/null || true
  fi
}

driver_down() {
  require_cmd docker
  docker rm -f "$(docker_container_name)" >/dev/null 2>&1 || true
  if in_container; then
    docker network rm "$(docker_network)" >/dev/null 2>&1 || true
  fi
}

# driver_gate - HTTP-only readiness for the standalone container. Standalone
# Rancher boots its embedded k3s, so allow ~10 min on cold CI runners. There is
# no in-cluster rollout/webhook/capi to watch; TLS is self-signed so curl uses
# -k (the e2e framework sets NODE_TLS_REJECT_UNAUTHORIZED=0 to match).
driver_gate() {
  local host="${1:?endpoint required}"
  log_info "waiting: dashboard responds 200"
  retry 60 10 "dashboard HTTP 200" -- \
    sh -c "curl -skI --max-time 5 'https://${host}/dashboard/' | head -1 | grep -q ' 200'"
  log_info "waiting: /v3-public/authProviders/local responds 200"
  retry 40 5 "authProviders API 200" -- \
    sh -c "curl -sk --max-time 5 -o /dev/null -w '%{http_code}' 'https://${host}/v3-public/authProviders/local' | grep -q 200"
}

# driver_settle - optional quiescence check mirroring k3d's, against the
# rancher container CPU so the test phase does not race boot-time churn.
#
# `docker stats` reports CPUPerc normalised so that 100% == one full core; on a
# multi-core host it can far exceed 100%. Divide by the number of cores the
# container sees to get a node-utilisation percentage, so the threshold means
# "fraction of the whole node" and does not stall on a fraction of one core.
driver_settle() {
  local threshold=50 settle_samples=3 sample_interval=10 max_attempts=30
  local low_streak=0 cpu i
  local node="muster-docker-${INSTANCE}"
  local ncpu
  ncpu=$(docker exec "$node" nproc 2>/dev/null || nproc 2>/dev/null || echo 1)
  [ "${ncpu:-0}" -ge 1 ] 2>/dev/null || ncpu=1
  for ((i = 1; i <= max_attempts; i++)); do
    cpu=$(docker stats --no-stream --format '{{.CPUPerc}}' "$node" 2>/dev/null \
      | tr -d '%' | cut -d. -f1)
    cpu=${cpu:-0}
    cpu=$((cpu / ncpu))
    if [ "$cpu" -lt "$threshold" ]; then
      low_streak=$((low_streak + 1))
      log_info "  cpu=${cpu}% (low ${low_streak}/${settle_samples})"
      [ "$low_streak" -ge "$settle_samples" ] && return 0
    else
      low_streak=0
      log_info "  cpu=${cpu}% (busy, streak reset)"
    fi
    sleep "$sample_interval"
  done
  return 1
}
