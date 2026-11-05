# shellcheck shell=bash
# The container's entrypoint. Runs as root, decides who should actually own
# the session, and execs the command.
#
# `cc_path` is injected by pkgs/claude-container/default.nix and holds the
# PATH from the image's own config. It has to be put back by hand:
# writeShellApplication prepends its runtimeInputs to PATH, and that prefix
# would otherwise be inherited by claude and shadow ~/.nix-profile -- the one
# directory that has to come first, since it is where Claude installs its own
# tools.
#
# CC_UID / CC_GID come from the wrapper:
#
#   0:0    the runtime is rootless, so container root is already the host user.
#          Nothing to do: root owns /nix, and workspace writes land as you.
#   N:M    the runtime is a rootful daemon, where container root is real root
#          and anything written into the bind-mounted workspace would come
#          back owned by root. Run as N:M instead -- which means /nix has to
#          belong to N:M too, hence the one-time chown below.
set -euo pipefail

export PATH="$cc_path"

uid="${CC_UID:-0}"
gid="${CC_GID:-0}"
home="${HOME:-/home/claude}"

if [ "$(id -u)" = 0 ] && [ "$uid" != 0 ]; then
    # Some tools (git, ssh, nix itself) want to resolve the uid they run as.
    if ! grep -q "^[^:]*:x:$gid:" /etc/group; then
        printf 'claude:x:%s:\n' "$gid" >>/etc/group
    fi
    if ! grep -q "^[^:]*:x:$uid:" /etc/passwd; then
        printf 'claude:x:%s:%s:claude:%s:/bin/bash\n' "$uid" "$gid" "$home" >>/etc/passwd
    fi

    # Once per /nix volume, not once per run: the stamp lives in the volume.
    # With --ephemeral there is no volume and /nix is the image's overlay, so
    # this copies up the whole store every time -- which is why --ephemeral
    # is documented as the slow option on a rootful daemon.
    stamp=/nix/.claude-container-owner
    if [ "$(cat "$stamp" 2>/dev/null || true)" != "$uid:$gid" ]; then
        printf 'claude-container: giving /nix to %s:%s (once per store)\n' "$uid" "$gid" >&2
        chown -R "$uid:$gid" /nix
        printf '%s:%s\n' "$uid" "$gid" >"$stamp"
        chown "$uid:$gid" "$stamp"
    fi

    exec setpriv --reuid "$uid" --regid "$gid" --clear-groups -- "$@"
fi

exec "$@"
