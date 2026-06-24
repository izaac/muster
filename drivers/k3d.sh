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

# in_container - true when muster itself runs inside a container. Containerised
# runs drive the host Docker daemon and create sibling k3d containers, so the
# cluster's API and ingress are reached differently than from a host shell.
in_container() { [ -f /.dockerenv ]; }

driver_kubeconfig() {
  local kc
  kc="$(k3d kubeconfig write "$INSTANCE" 2>/dev/null)"
  # Inside a container the kubeconfig's 0.0.0.0/127.0.0.1 server address points
  # at the container itself. Rewrite it to the host gateway so kubectl reaches
  # the API published on the host (the matching TLS SAN is added at create time).
  if in_container; then
    sed -i \
      -e 's#https://0\.0\.0\.0:#https://host.docker.internal:#' \
      -e 's#https://127\.0\.0\.1:#https://host.docker.internal:#' \
      "$kc"
  fi
  printf '%s' "$kc"
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
  if [ -n "${EXTERNAL_HOSTNAME:-}" ]; then
    printf '%s' "$EXTERNAL_HOSTNAME"
  else
    printf '%s.sslip.io' "$(k3d_lb_ip)"
  fi
}

# driver_curl_url - the base URL gates should curl to reach the ingress.
# On Linux the bridge IP is routable, so use the sslip hostname directly.
# On macOS (Docker Desktop) the bridge lives in a VM and is unreachable from
# the host; curl must go through the port-mapped localhost with a Host header.
driver_curl_url() {
  if in_container || [ "$(uname -s)" = "Linux" ]; then
    printf 'https://%s' "$(driver_endpoint)"
  else
    printf 'https://127.0.0.1:%s' "$(k3d_https_port)"
  fi
}

driver_tunnel_port() {
  k3d_https_port
}

driver_up() {
  require_cmd k3d "run muster via its container image, or install k3d"
  require_cmd helm "run muster via its container image, or install helm"

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
  # Containerised muster reaches the API through the host gateway. k3d keeps its
  # default API bind (binding to host.docker.internal is not possible on Docker
  # Desktop), but we add host.docker.internal as a TLS SAN so the kubeconfig can
  # be rewritten to that address (see driver_kubeconfig) with a valid cert.
  if in_container; then
    create_args+=(--k3s-arg "--tls-san=host.docker.internal@server:*")
  fi
  if [ -n "${DASHBOARD_DIST:-}" ]; then
    [ -d "$DASHBOARD_DIST" ] || die "--dashboard-dist '$DASHBOARD_DIST' is not a directory"
    create_args+=(-v "${DASHBOARD_DIST}:/dashboard-dist@server:0")
  fi

  log_info "k3d: creating cluster $INSTANCE"
  k3d "${create_args[@]}"

  # Join the cluster network so the gates can reach the serverlb at its bridge IP
  # (<ip>.sslip.io). On Docker Desktop the bridge lives inside the VM and is not
  # routable from the host, so the muster container must be on the network itself.
  if in_container; then
    docker network connect "$(k3d_network)" "$(cat /etc/hostname)" 2>/dev/null || true
  fi

  local host
  host="$(driver_endpoint)"
  local resolves=0
  if command -v getent >/dev/null 2>&1; then
    getent hosts "$host" >/dev/null && resolves=1
  elif command -v dscacheutil >/dev/null 2>&1; then
    dscacheutil -q host -a name "$host" | grep -q ip_address && resolves=1
  else
    ping -c 1 "$host" >/dev/null 2>&1 && resolves=1
  fi

  if [ "$resolves" -eq 0 ]; then
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
