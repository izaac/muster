# Bash completion for muster. Install by sourcing this file from your
# ~/.bashrc, or drop it in a bash-completion directory, e.g.:
#   cp completions/muster.bash ~/.local/share/bash-completion/completions/muster
# shellcheck shell=bash

_muster() {
  local cur prev
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD - 1]}"

  local commands="up build-ui wait tunnel warmup down env show version help"
  local flags="--provider --instance --external --version --repo --password \
    --out --dashboard-src --dashboard-dist --dashboard-branch --node-bin \
    --kubeconfig --rancher-host --config --help"

  case "$prev" in
    --provider)
      mapfile -t COMPREPLY < <(compgen -W "k3d existing docker" -- "$cur")
      return
      ;;
    --repo)
      mapfile -t COMPREPLY < <(compgen -W "rancher-prime rancher-latest rancher-alpha rancher-community rancher-com-rc rancher-com-alpha" -- "$cur")
      return
      ;;
    --out)
      mapfile -t COMPREPLY < <(compgen -W "env cypress json" -- "$cur")
      return
      ;;
    --config | --dashboard-src | --dashboard-dist | --kubeconfig | --node-bin)
      mapfile -t COMPREPLY < <(compgen -f -- "$cur")
      return
      ;;
    --instance | --version | --password | --dashboard-branch | --rancher-host)
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
      up | build-ui | wait | tunnel | warmup | down | env | show | version | help)
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
