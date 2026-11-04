_auto_complete_shic() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Example: complete interfaces only if previous argument is --iface
    case $prev in
      --from-interface|-f|--to-interface|-t|--tailscale)
        local ifaces
        ifaces=$(ip -o link show | awk -F: '{gsub(/ /,"",$2); print $2}')
        # Use compgen to generate the matches
        COMPREPLY=( $(compgen -W "$ifaces" -- "$cur") )
        ;;
      *)
        # fallback: complete flags
        COMPREPLY=( $(compgen -W "--from-interface -f --to-interface -t --help -h --tailscale --dry-run" -- "$cur") )
        ;;
    esac
}

complete -F _auto_complete_shic shic

_auto_complete_iptables() {
  local cur prev
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"
  case $prev in
    --in-interface|-i|--out-interface|-o)
      local ifaces
      ifaces=$(ip -o link show | awk -F: '{gsub(/ /,"",$2); print $2}')
      # Use compgen to generate the matches
      COMPREPLY=( $(compgen -W "$ifaces" -- "$cur") )
      ;;
    *)
      if declare -f _iptables &>/dev/null; then
        _iptables
      fi
      ;;
  esac
}

complete -F _auto_complete_iptables iptables
