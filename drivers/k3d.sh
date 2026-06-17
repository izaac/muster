#!/usr/bin/env bash
# drivers/k3d.sh - k3d substrate driver.
#
# Driver contract (every driver defines exactly these four verbs):
#   driver_up         create/ensure the cluster; leave KUBECONFIG resolvable.
#   driver_down       destroy the cluster and sweep substrate state.
#   driver_kubeconfig print an absolute kubeconfig path on stdout.
#   driver_endpoint   print the in-cluster Rancher hostname (e.g. <ip>.sslip.io).
#
# Ported from k3d-rancher.sh (cluster create/delete, lb_ip, sslip). Internal
# mode only in Phase 1; external hostname handling lands in Phase 3.

[ -n "${_MUSTER_DRIVER_K3D_SH:-}" ] && return 0
_MUSTER_DRIVER_K3D_SH=1

# Instance index drives host-port offsets so sharded instances do not collide:
# e2e -> 0, e2e-1 -> 1, e2e-2 -> 2.
k3d_index() {
  case "$INSTANCE" in
    e2e) echo 0 ;;
    e2e-[0-9]) echo "${INSTANCE##*-}" ;;
    *) die "instance must be 'e2e' or 'e2e-<n>' (got '$INSTANCE')" ;;
  esac
}

k3d_network() { echo "k3d-${INSTANCE}"; }
k3d_https_port() { echo $(($(k3d_index) + 8443)); }
k3d_http_port() { echo $(($(k3d_index) + 8080)); }

driver_kubeconfig() {
  k3d kubeconfig write "$INSTANCE" 2>/dev/null
}

# k3d_kc <kubectl args...> - run kubectl against this instance's kubeconfig.
k3d_kc() {
  kubectl --kubeconfig "$(driver_kubeconfig)" "$@"
}

# k3d_lb_ip - the serverlb container's IP on the instance network.
k3d_lb_ip() {
  docker inspect "k3d-${INSTANCE}-serverlb" \
    --format "{{(index .NetworkSettings.Networks \"$(k3d_network)\").IPAddress}}"
}

driver_endpoint() {
  printf '%s.sslip.io' "$(k3d_lb_ip)"
}

driver_up() {
  require_cmd k3d "enter the devenv shell"
  require_cmd helm "enter the devenv shell"

  if k3d cluster list 2>/dev/null | awk '{print $1}' | grep -qx "$INSTANCE"; then
    log_info "k3d cluster '$INSTANCE' already exists, reusing it"
    return 0
  fi

  local create_args=(
    cluster create "$INSTANCE"
    --servers 1 --agents 0
    --image "${K3S_IMAGE:-rancher/k3s:v1.33.1-k3s1}"
    --network "$(k3d_network)"
    -p "$(k3d_https_port):443@loadbalancer"
    -p "$(k3d_http_port):80@loadbalancer"
    --wait --timeout 180s
  )
  if [ -n "${DASHBOARD_DIST:-}" ]; then
    [ -d "$DASHBOARD_DIST" ] || die "--dashboard-dist '$DASHBOARD_DIST' is not a directory"
    create_args+=(-v "${DASHBOARD_DIST}:/dashboard-dist@server:0")
  fi

  log_info "k3d: creating cluster $INSTANCE"
  k3d "${create_args[@]}"

  local host
  host="$(driver_endpoint)"
  if ! getent hosts "$host" >/dev/null; then
    k3d cluster delete "$INSTANCE" || true
    die "'$host' does not resolve - local DNS is blocking sslip.io"
  fi
}

driver_down() {
  require_cmd k3d
  k3d cluster delete "$INSTANCE" || true
}

# driver_settle - optional gate hook: wait until the k3d node CPU has been below
# the idle threshold for a few consecutive samples, so the test phase does not
# race controller chatter (fleet/turtles/leader-election still burn CPU after
# Kubernetes reports Ready). Returns non-zero if it never settles.
driver_settle() {
  local threshold=50 settle_samples=3 sample_interval=10 max_attempts=30
  local low_streak=0 cpu i node="k3d-${INSTANCE}-server-0"
  for ((i = 1; i <= max_attempts; i++)); do
    cpu=$(docker stats --no-stream --format '{{.CPUPerc}}' "$node" 2>/dev/null \
      | tr -d '%' | cut -d. -f1)
    cpu=${cpu:-0}
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
