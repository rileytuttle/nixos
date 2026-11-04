# shellcheck shell=bash
# Bash completion for the `balena` alias (balena-plus). Sourced from
# ~/.bash_aliases by home/balena.nix, after balena-cli's own oclif-generated
# completion, which supplies _balena_autocomplete for everything not handled
# here.
#
# Adds on top of oclif's completion:
#   - the wrapper's own commands (ssh, logs, ps, uuid, devices) at the top level
#   - device names for: ssh/logs/ps/uuid <device>, device <sub> <device>,
#     and --device <device>
# Device names come from `balena-plus __complete-devices`, which caches them
# for 10 minutes, so the first tab after that may take a few seconds.

_balena_plus_devices() {
    local IFS=$'\n'
    # shellcheck disable=SC2207
    COMPREPLY=($(compgen -W "$(balena-plus __complete-devices)" -- "$1"))
}

_balena_plus_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD - 1]}"
    local cmd="${COMP_WORDS[1]:-}"

    if [ "$prev" = "--device" ]; then
        _balena_plus_devices "$cur"
        return
    fi

    if [ "$COMP_CWORD" -eq 1 ]; then
        _balena_autocomplete
        # shellcheck disable=SC2207
        COMPREPLY+=($(compgen -W "ssh logs ps uuid devices" -- "$cur"))
        return
    fi

    case "$cmd" in
        ssh|logs|ps|uuid)
            if [ "$COMP_CWORD" -eq 2 ]; then
                _balena_plus_devices "$cur"
            fi
            return
            ;;
        devices)
            return
            ;;
        device)
            # Same slot cmd_passthrough resolves: device <sub> <device>,
            # except list/register, which take a fleet.
            if [ "$COMP_CWORD" -eq 3 ] && [[ "$cur" != -* ]] \
                && [[ "${COMP_WORDS[2]}" != list && "${COMP_WORDS[2]}" != register ]]; then
                _balena_plus_devices "$cur"
                return
            fi
            ;;
    esac

    _balena_autocomplete
}

complete -F _balena_plus_complete balena
