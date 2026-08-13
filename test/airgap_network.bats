#!/usr/bin/env bats
# Unit tests for the network half of the airgap: creating the cluster network so
# muster owns it, taking the default route away from the nodes so the cluster has
# no way out, and putting both back the way they were on teardown.
# Pure: container_cli is stubbed, no containers and no network are touched.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  . "$ROOT/lib/util.sh"
  # shellcheck source=../lib/airgap.sh
  . "$ROOT/lib/airgap.sh"
  INSTANCE=e2e
  CALLS="$BATS_TEST_TMPDIR/calls"
  : >"$CALLS"
  # Facts the stub answers from, set per test.
  EXISTING_NETWORKS=""
  EXISTING_CONTAINERS=""
  NETWORK_MEMBERS=""
  NETWORK_RM_FAILS=""
  ROUTED_NODES=""
  STICKY_NODES=""
  LB_MEMBERS=""

  # Defined here, after lib/util.sh, because that is where the real container_cli
  # comes from and it would otherwise overwrite the stub.
  container_cli() {
    printf '%s\n' "$*" >>"$CALLS"
    case "$1 $2" in
      "network inspect")
        printf '%s\n' "$EXISTING_NETWORKS" | grep -qx "$3" || return 1
        printf '{"name": "%s", "containers": {"id": {"name": "%s"}}}\n' "$3" "$NETWORK_MEMBERS"
        return 0
        ;;
      "network create") return 0 ;;
      "network rm")
        printf '%s\n' "$NETWORK_RM_FAILS" | grep -qx "$3" && return 1
        return 0
        ;;
      "network connect" | "network disconnect") return 0 ;;
    esac
    case "$1" in
      inspect)
        printf '%s\n' "$EXISTING_CONTAINERS" | grep -qx "$2" || return 1
        return 0
        ;;
      exec)
        # "$2" is the node, and only a node that exists answers at all. A node in
        # ROUTED_NODES still has a default route; STICKY_NODES models one that
        # keeps coming back, which is what a restarted node does.
        printf '%s\n' "$NETWORK_MEMBERS $LB_MEMBERS" | grep -qw "$2" || return 1
        case "${5:-}" in
          del)
            printf '%s\n' "$ROUTED_NODES" | grep -qx "$2" || return 1
            printf '%s\n' "$STICKY_NODES" | grep -qx "$2" && return 0
            ROUTED_NODES="$(printf '%s\n' "$ROUTED_NODES" | grep -vx "$2")"
            return 0
            ;;
          *)
            printf '%s\n' "$ROUTED_NODES" | grep -qx "$2" && printf 'default via 10.0.0.1 dev eth0\n'
            printf '10.42.0.0/24 dev cni0 scope link\n'
            return 0
            ;;
        esac
        ;;
      ps) printf '%s\n' "$NETWORK_MEMBERS" ;;
    esac
    return 0
  }
}

called() { grep -qF -- "$1" "$CALLS"; }

# --- airgap_network_up -------------------------------------------------------

@test "airgap_network_up creates a labelled network when none exists" {
  run airgap_network_up k3d-e2e
  [ "$status" -eq 0 ]
  called "network create --label muster.airgap=1 k3d-e2e"
}

@test "airgap_network_up leaves an existing network exactly as it is" {
  EXISTING_NETWORKS="k3d-e2e"
  run airgap_network_up k3d-e2e
  [ "$status" -eq 0 ]
  run called "network create"
  [ "$status" -ne 0 ]
}

@test "airgap_network_up does not create the network as internal" {
  # An --internal network has a gateway but installs no default route, and k3s
  # refuses to start without one, so the route must exist while the node boots.
  run airgap_network_up k3d-e2e
  [ "$status" -eq 0 ]
  run called "--internal"
  [ "$status" -ne 0 ]
}

# --- airgap_seal_network -----------------------------------------------------

@test "airgap_seal_network takes the default route off every node" {
  EXISTING_NETWORKS="k3d-e2e"
  NETWORK_MEMBERS="k3d-e2e-server-0"
  ROUTED_NODES="k3d-e2e-server-0"
  run airgap_seal_network k3d-e2e
  [ "$status" -eq 0 ]
  [[ "$output" == *"sealed 1 node"* ]]
  called "exec k3d-e2e-server-0 ip route del default"
}

@test "airgap_seal_network fails when a node keeps its route (a restart undid it)" {
  EXISTING_NETWORKS="k3d-e2e"
  NETWORK_MEMBERS="k3d-e2e-server-0"
  ROUTED_NODES="k3d-e2e-server-0"
  STICKY_NODES="k3d-e2e-server-0"
  run airgap_seal_network k3d-e2e
  [ "$status" -ne 0 ]
  [[ "$output" == *"still has a route off the subnet"* ]]
}

@test "airgap_seal_network leaves the load balancer alone (it is the way in)" {
  EXISTING_NETWORKS="k3d-e2e"
  NETWORK_MEMBERS=""
  LB_MEMBERS="k3d-e2e-serverlb"
  ROUTED_NODES="k3d-e2e-serverlb"
  run airgap_seal_network k3d-e2e
  run called "exec k3d-e2e-serverlb"
  [ "$status" -ne 0 ]
}

@test "airgap_seal_network warns rather than passing silently when it sealed nothing" {
  EXISTING_NETWORKS="k3d-e2e"
  run airgap_seal_network k3d-e2e
  [ "$status" -ne 0 ]
  [[ "$output" == *"no node"* ]]
}

@test "airgap_seal_network is idempotent for an already sealed node" {
  # Deleting the route fails because there is none, but the node is verified
  # sealed all the same, which is what re-asserting after a settle relies on.
  EXISTING_NETWORKS="k3d-e2e"
  NETWORK_MEMBERS="k3d-e2e-server-0"
  ROUTED_NODES="k3d-e2e-server-0"
  run airgap_seal_network k3d-e2e
  [ "$status" -eq 0 ]
  [[ "$output" == *"sealed 1 node"* ]]
}

# --- airgap_registry_detach --------------------------------------------------

@test "airgap_registry_detach disconnects the registry so the network can go" {
  EXISTING_CONTAINERS="muster-registry-e2e"
  EXISTING_NETWORKS="k3d-e2e"
  run airgap_registry_detach k3d-e2e
  [ "$status" -eq 0 ]
  called "network disconnect k3d-e2e muster-registry-e2e"
}

@test "airgap_registry_detach is a no-op when there is no registry" {
  EXISTING_NETWORKS="k3d-e2e"
  run airgap_registry_detach k3d-e2e
  [ "$status" -eq 0 ]
  run called "network disconnect"
  [ "$status" -ne 0 ]
}

@test "airgap_registry_detach is a no-op when the network is already gone" {
  EXISTING_CONTAINERS="muster-registry-e2e"
  run airgap_registry_detach k3d-e2e
  [ "$status" -eq 0 ]
  run called "network disconnect"
  [ "$status" -ne 0 ]
}

# --- airgap_network_down -----------------------------------------------------

@test "airgap_network_down removes the cluster network once it is empty" {
  EXISTING_NETWORKS="k3d-e2e"
  run airgap_network_down k3d-e2e
  [ "$status" -eq 0 ]
  [[ "$output" == *"removed network k3d-e2e"* ]]
}

@test "airgap_network_down leaves a network that still has containers on it" {
  # A downstream sharing the management network keeps it alive; removal fails and
  # that is the intended outcome, not an error.
  EXISTING_NETWORKS="k3d-e2e"
  NETWORK_RM_FAILS="k3d-e2e"
  run airgap_network_down k3d-e2e
  [ "$status" -eq 0 ]
  [[ "$output" != *"removed network"* ]]
}

@test "airgap_network_down is a no-op for a network that never existed" {
  run airgap_network_down k3d-e2e-1
  [ "$status" -eq 0 ]
  run called "network rm"
  [ "$status" -ne 0 ]
}
