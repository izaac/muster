#!/usr/bin/env bats
# Unit tests for the post-deploy gates in lib/gates.sh: the ClusterRepo retry
# nudge, `--ui-offline auto` reconciliation, and the deployed-build assertions.
#
# kubectl, curl and the cluster are stubbed: these assert the decisions and the
# commands those decisions would run.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck source=../lib/util.sh
  . "$ROOT/lib/util.sh"
  # shellcheck source=../lib/ui.sh
  . "$ROOT/lib/ui.sh"
  # shellcheck source=../lib/gates.sh
  . "$ROOT/lib/gates.sh"

  PATCH_LOG="$BATS_TEST_TMPDIR/patches"
  ENV_LOG="$BATS_TEST_TMPDIR/env"
  : >"$PATCH_LOG"
  : >"$ENV_LOG"

  WEBHOOK_DEPLOY_RC=1
  CLUSTERREPO_STATE=""
  WEBHOOK_PODS=""
  PIN=""
  SETTING=""
  DEPLOYED_IMAGE=""
  RANCHERVERSION_BODY=""

  unset MUSTER_UI_OFFLINE DASHBOARD_DIST METADATA_REGISTRY CHANNEL_SOURCE RANCHER_REPO
  unset RANCHER_IMAGE_TAG RANCHER_IMAGE_TAG_RESOLVED MUSTER_REQUIRE_RANCHERVERSION AIRGAP
}

kubectl() {
  local joined="$*"
  case "$joined" in
    *"get deploy rancher-webhook"*) return "$WEBHOOK_DEPLOY_RC" ;;
    *"get clusterrepo.catalog.cattle.io rancher-charts"*) printf '%s' "$CLUSTERREPO_STATE" ;;
    *"patch clusterrepo.catalog.cattle.io rancher-charts"*) printf '%s\n' "$joined" >>"$PATCH_LOG" ;;
    *"get po -l app=rancher-webhook"*) printf '%s' "$WEBHOOK_PODS" ;;
    *"exec deploy/rancher"*) printf '%s' "$PIN" ;;
    *"set env deploy/rancher"*) printf '%s\n' "$joined" >>"$ENV_LOG" ;;
    *"rollout status deploy/rancher"*) return 0 ;;
    *"get settings.management.cattle.io ui-offline-preferred"*) printf '%s' "$SETTING" ;;
    *"get deploy rancher -o jsonpath"*) printf '%s' "$DEPLOYED_IMAGE" ;;
  esac
  return 0
}

curl() { printf '%s' "$RANCHERVERSION_BODY"; }

# --- the ClusterRepo retry nudge ---------------------------------------------

@test "the nudge forces a retry when rancher-charts is backing off" {
  CLUSTERREPO_STATE='False|Get "https://git.rancher.io/charts": Will retry after 5m'
  run gates_nudge_chart_repos /tmp/kc
  [ "$status" -eq 0 ]
  [[ "$output" == *"nudge: clusterrepo/rancher-charts failed download; forcing immediate retry"* ]]
  grep -q 'patch clusterrepo.catalog.cattle.io rancher-charts --type=merge' "$PATCH_LOG"
  grep -q 'forceUpdate' "$PATCH_LOG"
}

@test "the nudge matches HTTP and timeout messages, not just 'Will retry'" {
  for msg in '502 Bad Gateway' '503 Service Unavailable' 'i/o timeout' 'unexpected client error'; do
    : >"$PATCH_LOG"
    CLUSTERREPO_STATE="False|${msg}"
    gates_nudge_chart_repos /tmp/kc >/dev/null
    [ -s "$PATCH_LOG" ] || {
      echo "did not nudge for: $msg"
      false
    }
  done
}

@test "the nudge stays quiet when the download succeeded" {
  CLUSTERREPO_STATE='True|'
  run gates_nudge_chart_repos /tmp/kc
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$PATCH_LOG" ]
}

@test "the nudge stays quiet once rancher-webhook exists" {
  WEBHOOK_DEPLOY_RC=0
  CLUSTERREPO_STATE='False|Will retry after 5m'
  run gates_nudge_chart_repos /tmp/kc
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$PATCH_LOG" ]
}

@test "the nudge ignores a failure that is not a retryable backoff" {
  CLUSTERREPO_STATE='False|forbidden: User cannot get resource'
  run gates_nudge_chart_repos /tmp/kc
  [ -z "$output" ]
  [ ! -s "$PATCH_LOG" ]
}

@test "the webhook wait nudges on every unsuccessful attempt" {
  WEBHOOK_PODS=""
  CLUSTERREPO_STATE='False|Will retry after 5m'
  run gates_webhook_ready /tmp/kc
  [ "$status" -ne 0 ]
  grep -q 'forceUpdate' "$PATCH_LOG"
}

@test "the webhook wait passes once the pod is 1/1 Running" {
  WEBHOOK_PODS='rancher-webhook-6d9f 1/1 Running 0 42s'
  run gates_webhook_ready /tmp/kc
  [ "$status" -eq 0 ]
  [ ! -s "$PATCH_LOG" ]
}

# --- --ui-offline reconciliation ---------------------------------------------

@test "auto keeps serving the image when the pin is a branch" {
  MUSTER_UI_OFFLINE=auto PIN=master SETTING='|true' RANCHER_IMAGE_TAG_RESOLVED=v2.15-head
  run gates_reconcile_ui_offline /tmp/kc
  [ "$status" -eq 0 ]
  [ ! -s "$ENV_LOG" ]
  [[ "$output" == *"serving the image UI"* ]]
}

@test "auto flips a head image holding a released UI to the CDN" {
  MUSTER_UI_OFFLINE=auto PIN=v2.14.2 SETTING='false|true' RANCHER_IMAGE_TAG_RESOLVED=v2.14-head
  run gates_reconcile_ui_offline /tmp/kc
  [ "$status" -eq 0 ]
  [[ "$output" == *"head image pins released UI v2.14.2; switching CATTLE_UI_OFFLINE_PREFERRED=false"* ]]
  grep -q 'set env deploy/rancher CATTLE_UI_OFFLINE_PREFERRED=false' "$ENV_LOG"
}

@test "auto leaves the deployment alone when the pod did not name a pin" {
  MUSTER_UI_OFFLINE=auto PIN="" SETTING='|true' RANCHER_IMAGE_TAG_RESOLVED=v2.15-head
  run gates_reconcile_ui_offline /tmp/kc
  [ "$status" -eq 0 ]
  [ ! -s "$ENV_LOG" ]
}

@test "auto uses the value Setting over the default when both are present" {
  MUSTER_UI_OFFLINE=auto PIN=master SETTING='true|false' RANCHER_IMAGE_TAG_RESOLVED=v2.15-head
  run gates_reconcile_ui_offline /tmp/kc
  [ "$status" -eq 0 ]
}

@test "the setting assertion dies when the env did not reach the deployment" {
  MUSTER_UI_OFFLINE=false SETTING='true|true'
  run gates_reconcile_ui_offline /tmp/kc
  [ "$status" -ne 0 ]
  [[ "$output" == *"ui-offline-preferred=true, but --ui-offline false asked for false"* ]]
}

@test "true is asserted against the effective default setting" {
  MUSTER_UI_OFFLINE=true SETTING='|true'
  run gates_reconcile_ui_offline /tmp/kc
  [ "$status" -eq 0 ]
  [[ "$output" == *"ui-offline-preferred=true (true)"* ]]
}

@test "dynamic and a mounted dist ask for nothing" {
  MUSTER_UI_OFFLINE=dynamic SETTING='|false'
  run gates_reconcile_ui_offline /tmp/kc
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  MUSTER_UI_OFFLINE=false DASHBOARD_DIST=/tmp/dist SETTING='|true'
  run gates_reconcile_ui_offline /tmp/kc
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- the deployed-build assertions -------------------------------------------

@test "a metadata row must have deployed from the registry its branch names" {
  CHANNEL_SOURCE=metadata METADATA_REGISTRY=stgregistry.suse.com
  DEPLOYED_IMAGE=rancher/rancher:head
  run gates_verify_deployed_build /tmp/kc https://rancher.example.com
  [ "$status" -ne 0 ]
  [[ "$output" == *"deployed image 'rancher/rancher:head' does not come from metadata registry 'stgregistry.suse.com'"* ]]
}

@test "a metadata row accepts an image from its registry and skips the edition" {
  CHANNEL_SOURCE=metadata METADATA_REGISTRY=stgregistry.suse.com
  DEPLOYED_IMAGE=stgregistry.suse.com/rancher/rancher:v2.14-head
  RANCHERVERSION_BODY='{"RancherPrime":false}'
  run gates_verify_deployed_build /tmp/kc https://rancher.example.com
  [ "$status" -eq 0 ]
}

@test "an airgapped metadata row skips the registry check" {
  CHANNEL_SOURCE=metadata METADATA_REGISTRY=stgregistry.suse.com AIRGAP=true
  DEPLOYED_IMAGE=registry.local/rancher/rancher:head
  run gates_verify_deployed_build /tmp/kc https://rancher.example.com
  [ "$status" -eq 0 ]
}

@test "a prime row whose Rancher reports community fails" {
  CHANNEL_SOURCE=prime RANCHER_REPO=rancher-prime-ga
  RANCHERVERSION_BODY='{"RancherPrime":false,"Version":"v2.14.6"}'
  run gates_verify_deployed_build /tmp/kc https://rancher.example.com
  [ "$status" -ne 0 ]
  [[ "$output" == *"reports build type 'community' (/rancherversion RancherPrime=false), expected 'prime'"* ]]
}

@test "a prime row whose Rancher reports prime passes" {
  CHANNEL_SOURCE=prime RANCHER_REPO=rancher-prime-ga
  RANCHERVERSION_BODY='{"RancherPrime":true,"Version":"v2.14.6"}'
  run gates_verify_deployed_build /tmp/kc https://rancher.example.com
  [ "$status" -eq 0 ]
  [[ "$output" == *"deployed build type prime matches prime/rancher-prime-ga"* ]]
}

@test "a fixed community row expects community, however it was named" {
  CHANNEL_SOURCE=fixed RANCHER_REPO=rancher-com-rc
  RANCHERVERSION_BODY='{"RancherPrime":false}'
  run gates_verify_deployed_build /tmp/kc https://rancher.example.com
  [ "$status" -eq 0 ]

  RANCHERVERSION_BODY='{"RancherPrime":true}'
  run gates_verify_deployed_build /tmp/kc https://rancher.example.com
  [ "$status" -ne 0 ]
  [[ "$output" == *"expected 'community' for fixed/rancher-com-rc"* ]]
}

@test "the RancherPrime field is read case-insensitively" {
  CHANNEL_SOURCE=prime RANCHER_REPO=rancher-latest
  RANCHERVERSION_BODY='{"RancherPrime":"TRUE"}'
  run gates_verify_deployed_build /tmp/kc https://rancher.example.com
  [ "$status" -eq 0 ]
}

@test "an unanswered /rancherversion does not fail a row by default" {
  CHANNEL_SOURCE=prime RANCHER_REPO=rancher-prime-ga
  RANCHERVERSION_BODY=""
  run gates_verify_deployed_build /tmp/kc https://rancher.example.com
  [ "$status" -eq 0 ]
}

@test "MUSTER_REQUIRE_RANCHERVERSION makes silence a failure" {
  CHANNEL_SOURCE=prime RANCHER_REPO=rancher-prime-ga MUSTER_REQUIRE_RANCHERVERSION=1
  RANCHERVERSION_BODY=""
  run gates_verify_deployed_build /tmp/kc https://rancher.example.com
  [ "$status" -ne 0 ]
  [[ "$output" == *"never answered, so the build type"* ]]
}
