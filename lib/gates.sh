#!/usr/bin/env bash
# lib/gates.sh - readiness gates run after the chart install.
#
# Provider-blind: everything here talks to the cluster through the driver
# contract (driver_kubeconfig, driver_endpoint) and plain HTTPS. A driver may
# optionally define driver_settle for a substrate-specific quiescence check
# (e.g. k3d node CPU); gates_wait calls it last when present.
#
# Ported from k3d-rancher.sh do_wait (internal-mode gates). External-only steps
# (server-url pin, system-store, warm-up) live in lib/external.sh + lib/warmup.sh.

[ -n "${_MUSTER_GATES_SH:-}" ] && return 0
_MUSTER_GATES_SH=1

# gates_nudge_chart_repos <kc> - force an immediate retry of the rancher-charts
# ClusterRepo when its download is stuck in a backoff.
#
# rancher-webhook comes from that repo, and a failed download is retried on a
# five-minute timer, so a cold cluster can spend most of the gate's budget
# waiting for a retry that a single forceUpdate would start now. Best-effort by
# construction: a gate must never fail because a nudge could not be read applied.
gates_nudge_chart_repos() {
  local kc="${1:?kubeconfig required}" state status message
  # Once the webhook deployment exists, its chart arrived and there is nothing to
  # nudge.
  kubectl --kubeconfig "$kc" -n cattle-system get deploy rancher-webhook >/dev/null 2>&1 && return 0

  state="$(kubectl --kubeconfig "$kc" get clusterrepo.catalog.cattle.io rancher-charts \
    -o jsonpath='{.status.conditions[?(@.type=="Downloaded")].status}|{.status.conditions[?(@.type=="Downloaded")].message}' \
    2>/dev/null || true)"
  [ -n "$state" ] || return 0
  status="${state%%|*}"
  message="${state#*|}"
  [ "$status" = False ] || return 0
  printf '%s\n' "$message" | grep -Eq 'Will retry after|50[0234]|timeout|unexpected client error' || return 0

  log_info "nudge: clusterrepo/rancher-charts failed download; forcing immediate retry"
  kubectl --kubeconfig "$kc" patch clusterrepo.catalog.cattle.io rancher-charts --type=merge \
    -p "{\"spec\":{\"forceUpdate\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}}" >/dev/null 2>&1 || true
}

# gates_webhook_ready <kc> - true once rancher-webhook is 1/1 Running, and nudges
# the chart repo on every unsuccessful attempt so a backoff is cut short.
gates_webhook_ready() {
  local kc="${1:?kubeconfig required}"
  if kubectl --kubeconfig "$kc" -n cattle-system get po -l app=rancher-webhook --no-headers 2>/dev/null \
    | grep -q '1/1.*Running'; then
    return 0
  fi
  gates_nudge_chart_repos "$kc"
  return 1
}

# gates_expected_edition - the build type this row asked for, or empty when the
# row names no edition. Pure.
#
# A metadata row follows whatever registry its branch publishes to, so it has no
# expectation to violate and is checked by its registry instead.
gates_expected_edition() {
  case "${CHANNEL_SOURCE:-fixed}" in
    prime | prime-head | prime-ga)
      printf 'prime'
      return 0
      ;;
    community-ga)
      printf 'community'
      return 0
      ;;
    metadata) return 0 ;;
  esac
  case "${RANCHER_REPO:-}" in
    rancher-prime | rancher-prime-ga | rancher-latest | rancher-alpha) printf 'prime' ;;
    rancher-community | rancher-com-*) printf 'community' ;;
  esac
}

# gates_reconcile_ui_offline <kc> - resolve `--ui-offline auto` after the rollout,
# and assert the setting that was asked for.
#
# `auto` is deployed as CATTLE_UI_OFFLINE_PREFERRED=true and reconsidered here,
# because the UI the image embeds is only knowable from the running pod: the pin
# is a build-time env var. Changing the deployment's env (not the Setting) is
# what takes effect, since Rancher rewrites the Setting from the env on every
# start.
gates_reconcile_ui_offline() {
  local kc="${1:?kubeconfig required}" mode="${MUSTER_UI_OFFLINE:-}"
  [ -z "${DASHBOARD_DIST:-}" ] || return 0
  [ -n "$mode" ] || return 0
  [ "$mode" != dynamic ] || return 0

  local expected=true pin="" tag effective value default eff
  case "$mode" in
    false) expected=false ;;
    auto)
      pin="$(kubectl --kubeconfig "$kc" -n cattle-system exec deploy/rancher -c rancher -- \
        printenv CATTLE_DASHBOARD_UI_VERSION 2>/dev/null | tr -d '\r\n' || true)"
      tag="${RANCHER_IMAGE_TAG_RESOLVED:-${RANCHER_IMAGE_TAG:-head}}"
      if [ -n "$pin" ] && ! ui_auto_serve_from_image "$tag" "$pin"; then
        expected=false
        log_info "ui-offline=auto: head image pins released UI ${pin}; switching CATTLE_UI_OFFLINE_PREFERRED=false"
        kubectl --kubeconfig "$kc" -n cattle-system set env deploy/rancher \
          CATTLE_UI_OFFLINE_PREFERRED=false >/dev/null
        kubectl --kubeconfig "$kc" -n cattle-system rollout status deploy/rancher --timeout=300s
      else
        log_info "ui-offline=auto: serving the image UI (pin ${pin:-unknown}, backend ${tag})"
      fi
      ;;
    *) expected="$mode" ;;
  esac

  effective="$(kubectl --kubeconfig "$kc" get settings.management.cattle.io ui-offline-preferred \
    -o jsonpath='{.value}|{.default}' 2>/dev/null || true)"
  value="${effective%%|*}"
  default=""
  case "$effective" in
    *'|'*) default="${effective#*|}" ;;
  esac
  # `value` is what an operator set, `default` is what the deployment was given,
  # which is where CATTLE_ env vars land.
  eff="${value:-$default}"
  eff="$(printf '%s' "$eff" | tr '[:upper:]' '[:lower:]')"
  if [ "$eff" != "$expected" ]; then
    die "ui-offline-preferred=${eff:-unset}, but --ui-offline ${mode} asked for ${expected}. CATTLE_UI_OFFLINE_PREFERRED did not reach the deployment"
  fi
  log_info "ui-offline-preferred=${eff} (${mode})"
}

# gates_verify_deployed_build <kc> <curl_url> - assert the deployed build is the
# one the row asked for: the branch's registry for a metadata row, and the
# edition the channel names for a row that names one.
#
# Both are read back rather than restated: a Prime chart can carry a
# systemDefaultRegistry of its own, and the channel is a poor proxy for the
# edition (a metadata head repo says nothing about it).
gates_verify_deployed_build() {
  local kc="${1:?kubeconfig required}" curl_url="${2:?url required}" deployed_img body rp got expected
  if [ "${CHANNEL_SOURCE:-fixed}" = metadata ] && [ -n "${METADATA_REGISTRY:-}" ] \
    && ! is_true "${AIRGAP:-}"; then
    deployed_img="$(kubectl --kubeconfig "$kc" -n cattle-system get deploy rancher \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    if [ -n "$deployed_img" ]; then
      case "$deployed_img" in
        "${METADATA_REGISTRY}"/*) ;;
        *) die "channel-source metadata: deployed image '${deployed_img}' does not come from metadata registry '${METADATA_REGISTRY}'" ;;
      esac
    fi
  fi

  expected="$(gates_expected_edition)"
  [ -n "$expected" ] || return 0
  body="$(curl -skL --max-time 10 "${curl_url%/}/rancherversion" 2>/dev/null || true)"
  if ! printf '%s' "$body" | grep -q '"RancherPrime"'; then
    # An endpoint that did not answer proves nothing, so a row that only mocks
    # /dashboard/ keeps working; asking for the stricter check makes silence a
    # failure, which is what a CI row naming an edition needs.
    is_true "${MUSTER_REQUIRE_RANCHERVERSION:-}" \
      && die "${curl_url%/}/rancherversion never answered, so the build type of this ${CHANNEL_SOURCE:-fixed}/${RANCHER_REPO:-} row could not be confirmed"
    return 0
  fi
  rp="$(printf '%s' "$body" | sed -n 's/.*"RancherPrime"[[:space:]]*:[[:space:]]*\([Tt][Rr][Uu][Ee]\|[Ff][Aa][Ll][Ss][Ee]\).*/\1/p' | head -1)"
  [ -n "$rp" ] || return 0
  case "$rp" in
    [Tt][Rr][Uu][Ee]) got=prime ;;
    *) got=community ;;
  esac
  if [ "$got" != "$expected" ]; then
    die "deployed Rancher reports build type '${got}' (/rancherversion RancherPrime=${rp}), expected '${expected}' for ${CHANNEL_SOURCE:-fixed}/${RANCHER_REPO:-}"
  fi
  log_info "deployed build type ${got} matches ${CHANNEL_SOURCE:-fixed}/${RANCHER_REPO:-}"
}

# gates_wait - block until Rancher is serving and its controllers are ready.
#
# A driver that ships Rancher itself (e.g. docker standalone, where the
# container IS rancher) may define driver_gate to run provider-specific
# HTTP-only readiness checks; gates_wait delegates to it and skips the
# in-cluster kubectl gates (rollout/webhook/capi) which do not apply. Drivers
# on a real cluster leave driver_gate undefined and get the kubectl path.
gates_wait() {
  local kc host
  kc="$(driver_kubeconfig)"
  host="$(driver_endpoint)"

  # In airgap a gate can be waiting on a pod that will never start, because it
  # names an image no published list carries and only the running cluster knows
  # about. Repair between attempts so the wait is doing something about what it
  # is waiting for, rather than timing out on a fixable gap.
  if is_true "${AIRGAP:-}" && [ -n "${MIRROR_REGISTRY:-}" ] && [ -n "$kc" ]; then
    # shellcheck disable=SC2034  # read by retry in lib/util.sh
    MUSTER_RETRY_HOOK=(mirror_heal_pulls "$kc" "$MIRROR_REGISTRY")
  fi
  if declare -F driver_gate >/dev/null; then
    driver_gate "$host"
  else
    log_info "waiting: rancher deployment rollout"
    kubectl --kubeconfig "$kc" -n cattle-system rollout status deploy/rancher --timeout=600s

    if is_true "${EXTERNAL:-}"; then
      external_apply "$kc" "$host"
    fi

    # After the rollout, and before anything reads the UI: resolving `auto` can
    # roll the deployment once more when the image turns out to embed a released
    # UI.
    gates_reconcile_ui_offline "$kc"

    log_info "waiting: dashboard responds 200"
    local curl_url="https://${host}"
    local curl_host_flag=""
    if declare -F driver_curl_url >/dev/null; then
      curl_url="$(driver_curl_url)"
      [ "$curl_url" != "https://${host}" ] && curl_host_flag="-H 'Host: ${host}'"
    fi
    retry 20 5 "dashboard HTTP 200" -- \
      bash -c "curl -skI --max-time 5 $curl_host_flag '${curl_url}/dashboard/' | head -1 | grep -q ' 200'"

    # Read back what deployed: the branch's registry for a metadata row, and the
    # edition the channel names for a row that names one.
    gates_verify_deployed_build "$kc" "$curl_url"

    # 90 attempts (15 min) covers cold CI runners where CRD apply + webhook chart
    # install saturate the node and gate timing varies run-to-run. Locally ~90s.
    log_info "waiting: rancher-webhook pod ready"
    # A stuck rancher-charts download backs off for five minutes; nudge it before
    # the wait so the cold-start clock is not spent waiting on the timer.
    gates_nudge_chart_repos "$kc"
    retry 90 10 "rancher-webhook 1/1 Running" -- gates_webhook_ready "$kc"

    # head (>=2.15, Turtles) deploys CAPI into cattle-capi-system; older lines used
    # cattle-provisioning-capi-system. Accept either.
    log_info "waiting: capi-webhook-service exists"
    retry 90 10 "capi-webhook-service" -- \
      sh -c "kubectl --kubeconfig '$kc' -n cattle-capi-system get service capi-webhook-service 2>/dev/null \
        || kubectl --kubeconfig '$kc' -n cattle-provisioning-capi-system get service capi-webhook-service 2>/dev/null"

    # Deeper than the dashboard page: proves the auth provider API is serving.
    log_info "waiting: /v3-public/authProviders/local responds 200"
    retry 20 5 "authProviders API 200" -- \
      bash -c "curl -sk --max-time 5 -o /dev/null -w '%{http_code}' $curl_host_flag '${curl_url}/v3-public/authProviders/local' | grep -q 200"

  fi

  if declare -F driver_settle >/dev/null; then
    log_info "waiting: substrate to settle"
    driver_settle || log_warn "substrate did not settle in time - proceeding anyway"
  fi

  # Anything that restarts a node during bring-up gives it a fresh network
  # namespace, and with it a default route, so an airgap can quietly come back
  # online between the seal and here. Assert it once more now that the cluster
  # has stopped moving, and say so plainly if it could not be re-applied.
  if is_true "${AIRGAP:-}" && declare -F driver_reseal >/dev/null; then
    driver_reseal || log_warn "airgap: the cluster has a route to the internet; results are not airgapped"
  fi

  # warmup_provisioning drives kubectl; only meaningful when the driver
  # exposes a kubeconfig (k3d/existing), not for the docker standalone path.
  if is_true "${EXTERNAL:-}" && [ -n "$kc" ]; then
    warmup_provisioning "$kc"
  fi

  log_ok "rancher ready: https://${host}/dashboard"
}
