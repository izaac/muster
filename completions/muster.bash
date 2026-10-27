# Bash completion for muster. Install by sourcing this file from your
# ~/.bashrc, or drop it in a bash-completion directory, e.g.:
#   cp completions/muster.bash ~/.local/share/bash-completion/completions/muster
# shellcheck shell=bash

_muster() {
  local cur prev
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD - 1]}"

  local commands="up build-ui wait tunnel warmup import mirror down env show version help"
  local flags="--provider --instance --external --version --repo --channel-source \
    --password --image-tag --out --registry --airgap --insecure-registry \
    --mirror-all --mirror-extension --k3k-version --k3s-versions --from-cluster \
    --import-instance --management-instance --dashboard-src --dashboard-dist \
    --dashboard-branch --ui-offline --replicas --servers --node-bin --kubeconfig --rancher-host --config --dry-run \
    --prefer-staging --help"

  case "$prev" in
    --provider)
      mapfile -t COMPREPLY < <(compgen -W "k3d existing docker" -- "$cur")
      return
      ;;
    --repo)
      mapfile -t COMPREPLY < <(compgen -W "rancher-prime rancher-prime-ga rancher-latest rancher-alpha rancher-community rancher-com-rc rancher-com-alpha" -- "$cur")
      return
      ;;
    --channel-source)
      mapfile -t COMPREPLY < <(compgen -W "fixed metadata prime prime-head prime-ga community-ga" -- "$cur")
      return
      ;;
    --out)
      mapfile -t COMPREPLY < <(compgen -W "env cypress json" -- "$cur")
      return
      ;;
    --ui-offline)
      mapfile -t COMPREPLY < <(compgen -W "true false dynamic auto" -- "$cur")
      return
      ;;
    --replicas | --servers)
      mapfile -t COMPREPLY < <(compgen -W "1 3" -- "$cur")
      return
      ;;
    --config | --dashboard-src | --dashboard-dist | --kubeconfig | --node-bin)
      mapfile -t COMPREPLY < <(compgen -f -- "$cur")
      return
      ;;
    --instance | --version | --password | --image-tag | --registry | --k3k-version | --k3s-versions | --import-instance | --management-instance | --dashboard-branch | --rancher-host)
      return
      ;;
  esac

  if [[ "$cur" == -* ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$flags" -- "$cur")
    return
  fi

  # Offer the subcommand only until one has been chosen.
  local i cmd_seen=""
  for ((i = 1; i < COMP_CWORD; i++)); do
    case "${COMP_WORDS[i]}" in
      up | build-ui | wait | tunnel | warmup | import | mirror | down | env | show | version | help)
        cmd_seen=1
        break
        ;;
    esac
  done
  if [[ -z "$cmd_seen" ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$commands" -- "$cur")
  fi
}

complete -F _muster muster
