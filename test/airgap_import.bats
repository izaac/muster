#!/usr/bin/env bats
# Unit tests for the airgap-import wiring: the registry/network override hooks
# that let a second cluster share the management registry and network, the
# cert-manager OCI reference, its pins, and downstream instance selection.
# Pure: no containers, no network. k3d is stubbed where needed.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  . "$ROOT/lib/util.sh"
  # shellcheck source=../lib/helm.sh
  . "$ROOT/lib/helm.sh"
  # shellcheck source=../lib/airgap.sh
  . "$ROOT/lib/airgap.sh"
  # shellcheck source=../drivers/k3d.sh
  . "$ROOT/drivers/k3d.sh"
  # shellcheck source=../lib/import.sh
  . "$ROOT/lib/import.sh"
  unset MUSTER_REGISTRY_INSTANCE MUSTER_K3D_NETWORK
}

# --- registry/network override hooks ----------------------------------------

@test "airgap_registry_name keys on INSTANCE by default" {
  INSTANCE=e2e
  [ "$(airgap_registry_name)" = "muster-registry-e2e" ]
}

@test "airgap_registry_name honours MUSTER_REGISTRY_INSTANCE (shared registry)" {
  INSTANCE=e2e-1
  MUSTER_REGISTRY_INSTANCE=e2e
  [ "$(airgap_registry_name)" = "muster-registry-e2e" ]
}

@test "k3d_network defaults to this instance's own network" {
  INSTANCE=e2e
  [ "$(k3d_network)" = "k3d-e2e" ]
}

@test "k3d_network honours MUSTER_K3D_NETWORK (join management network)" {
  INSTANCE=e2e-1
  MUSTER_K3D_NETWORK=k3d-e2e
  [ "$(k3d_network)" = "k3d-e2e" ]
}

# --- airgap_repo_path (agent image must not carry a registry in airgap) ------

@test "airgap_repo_path strips a registry host from a fully qualified image" {
  [ "$(airgap_repo_path stgregistry.suse.com/rancher/rancher-agent)" = "rancher/rancher-agent" ]
}

@test "airgap_repo_path strips a host:port registry" {
  [ "$(airgap_repo_path localhost:5000/rancher/rancher-agent)" = "rancher/rancher-agent" ]
}

@test "airgap_repo_path leaves a bare repository path alone" {
  [ "$(airgap_repo_path rancher/rancher-agent)" = "rancher/rancher-agent" ]
}

# --- cert-manager OCI reference + pins ---------------------------------------

@test "helm_cert_manager_oci_ref is empty when not airgapped" {
  AIRGAP=false
  MIRROR_REGISTRY=localhost:5000
  [ -z "$(helm_cert_manager_oci_ref)" ]
}

@test "helm_cert_manager_oci_ref points at the mirror when airgapped" {
  AIRGAP=true
  MIRROR_REGISTRY=localhost:5000
  [ "$(helm_cert_manager_oci_ref)" = "oci://localhost:5000/jetstack/charts/cert-manager" ]
}

@test "helm_cert_manager_oci_ref is empty when airgap names no registry" {
  AIRGAP=true
  unset MIRROR_REGISTRY
  [ -z "$(helm_cert_manager_oci_ref)" ]
}

@test "cert-manager default version matches the Jenkins matrix (v1.19.4)" {
  [ "$CERT_MANAGER_VERSION_DEFAULT" = "v1.19.4" ]
}

@test "cert-manager v1.19.4 CRDs checksum is pinned" {
  [ "${MUSTER_CERT_MANAGER_CRDS_SHA256[v1.19.4]}" = "0e09c26d64fbdb56f2ea95b5b2350991980a184a9ce9a09d3a9a207594ce38b0" ]
}

@test "cert-manager v1.16.2 pin is retained for back-compat" {
  [ -n "${MUSTER_CERT_MANAGER_CRDS_SHA256[v1.16.2]}" ]
}

# --- airgap strict registry config (no upstream fallback) --------------------

@test "airgap_hosts_toml has no server line (no internet fallback)" {
  INSTANCE=e2e
  run airgap_hosts_toml localhost:5000 true
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'server'
}

@test "airgap_hosts_toml points at the in-cluster mirror name, insecure http" {
  INSTANCE=e2e
  run airgap_hosts_toml localhost:5000 true
  echo "$output" | grep -q 'host."http://muster-registry-e2e:5000/v2"'
  echo "$output" | grep -q 'skip_verify = true'
}

@test "airgap_hosts_toml uses https and no skip_verify when secure" {
  INSTANCE=e2e
  run airgap_hosts_toml localhost:5000
  echo "$output" | grep -q 'host."https://muster-registry-e2e:5000/v2"'
  ! echo "$output" | grep -q 'skip_verify'
}

@test "airgap_write_certs_d writes a strict hosts.toml for every registry and the mirror" {
  INSTANCE=e2e
  MUSTER_AIRGAP_CERTS_DIR="$BATS_TEST_TMPDIR/certs"
  run airgap_write_certs_d localhost:5000 true
  [ "$status" -eq 0 ]
  local dir="$output"
  # every upstream registry, plus the mirror standing in for itself
  for reg in docker.io quay.io ghcr.io registry.suse.com stgregistry.suse.com registry.rancher.com "muster-registry-e2e:5000"; do
    [ -f "$dir/$reg/hosts.toml" ] || {
      echo "missing hosts.toml for $reg"
      false
    }
    ! grep -q 'server' "$dir/$reg/hosts.toml" || {
      echo "$reg has a server fallback"
      false
    }
  done
}

@test "import_pick_downstream returns the first free e2e-<n>" {
  k3d() { printf 'NAME\ne2e\n'; }
  export -f k3d
  [ "$(import_pick_downstream e2e)" = "e2e-1" ]
}

@test "import_pick_downstream skips existing downstream clusters" {
  k3d() { printf 'NAME\ne2e\ne2e-1\n'; }
  export -f k3d
  [ "$(import_pick_downstream e2e)" = "e2e-2" ]
}

@test "import_pick_downstream never returns the management instance" {
  k3d() { printf 'NAME\ne2e-1\n'; }
  export -f k3d
  [ "$(import_pick_downstream e2e-1)" = "e2e-2" ]
}

# --- import_is_downstream / import_management_instance (teardown routing) -----

@test "import_is_downstream is true for e2e-<n> and false for the base" {
  import_is_downstream e2e-1
  import_is_downstream e2e-9
  ! import_is_downstream e2e
  ! import_is_downstream e2e-0
}

@test "import_management_instance defaults to e2e by convention" {
  unset MANAGEMENT_INSTANCE
  [ "$(import_management_instance)" = "e2e" ]
}

@test "import_management_instance honours an explicit override" {
  MANAGEMENT_INSTANCE=e2e-2
  [ "$(import_management_instance)" = "e2e-2" ]
}

@test "import_teardown is a no-op when management equals the instance" {
  INSTANCE=e2e
  MANAGEMENT_INSTANCE=e2e
  run import_teardown
  [ "$status" -eq 0 ]
}

# --- import_registration_url -------------------------------------------------
# The token lags the cluster by a beat; until it lands, manifestUrl carries a
# literal "{token}" template, which must not be handed to kubectl.

@test "import_registration_url waits (returns non-zero) until the token lands" {
  kubectl() { printf ''; } # no tokenSecretName, no status.token
  export -f kubectl
  run import_registration_url /kc c-m-abc rancher.test
  [ "$status" -ne 0 ]
}

@test "import_registration_url reads the token from the referenced secret" {
  kubectl() {
    case "$*" in
      *tokenSecretName*) printf 'crt-token-default-token' ;;
      *secret*data.token*) printf 'dGstcmVhbA==' ;; # base64 of "tk-real"
      *manifestUrl*) printf 'https://rancher.test/v3/import/{token}_c-m-abc.yaml' ;;
      *) printf '' ;;
    esac
  }
  export -f kubectl
  [ "$(import_registration_url /kc c-m-abc rancher.test)" = "https://rancher.test/v3/import/tk-real_c-m-abc.yaml" ]
}

@test "import_registration_url falls back to the deprecated status.token" {
  kubectl() {
    case "$*" in
      *tokenSecretName*) printf '' ;;
      *status.token*) printf 'tk-old' ;;
      *manifestUrl*) printf 'https://rancher.test/v3/import/{token}_c-m-abc.yaml' ;;
      *) printf '' ;;
    esac
  }
  export -f kubectl
  [ "$(import_registration_url /kc c-m-abc rancher.test)" = "https://rancher.test/v3/import/tk-old_c-m-abc.yaml" ]
}

@test "import_registration_url uses a fully populated manifestUrl as-is" {
  kubectl() {
    case "$*" in
      *tokenSecretName*) printf 'crt-token-default-token' ;;
      *secret*data.token*) printf 'dGstcmVhbA==' ;;
      *manifestUrl*) printf 'https://rancher.test/v3/import/tk-real_c-m-abc.yaml' ;;
      *) printf '' ;;
    esac
  }
  export -f kubectl
  [ "$(import_registration_url /kc c-m-abc rancher.test)" = "https://rancher.test/v3/import/tk-real_c-m-abc.yaml" ]
}
