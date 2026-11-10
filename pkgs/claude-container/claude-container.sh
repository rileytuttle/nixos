# shellcheck shell=bash
# claude-container -- run Claude Code in a container over the directory you
# are standing in. Built by pkgs/claude-container/default.nix, which also
# injects the preamble above this comment:
#
#   image_streamer   executable that writes the OCI image to stdout
#   image_name       repository half of the tag
#   image_ref        name:tag, where the tag is a hash of the image contents
#   nix_volume       named volume holding the container's /nix
#   container_home   where the container's HOME is mounted inside
#   default_home     where that HOME lives on the host
#
# Usage text is in usage(). The runtime (podman or docker) comes from the
# caller's PATH on purpose -- see the PATH note in default.nix.
set -euo pipefail

prog="claude-container"

bold="" dim="" reset=""
if [ -t 2 ]; then
    bold=$'\e[1m' dim=$'\e[2m' reset=$'\e[0m'
fi

die() {
    printf '%s: %s\n' "$prog" "$1" >&2
    exit 1
}
warn() {
    printf '%s%s: %s%s\n' "$bold" "$prog" "$1" "$reset" >&2
}
note() {
    printf '%s%s: %s%s\n' "$dim" "$prog" "$1" "$reset" >&2
}

usage() {
    cat <<EOF
Usage: $prog [OPTIONS] [DIR...] [-- CLAUDE_ARGS...]

Runs Claude Code in a container. With no DIR the current directory is mounted
read-write at the same absolute path it has on the host, so Claude sees what
plain \`claude\` would see and its session and plan files line up with the
ones outside.

The container carries its own nix, and its /nix is a named volume, so what
Claude installs for itself stays installed:

    nix profile install nixpkgs#gcc nixpkgs#python3

Mounts
  --ro, --read-only    mount the positional DIRs read-only (default: writable)
  --mount DIR          additional read-write mount (repeatable)
  --mount-ro DIR       additional read-only mount (repeatable)
  --home DIR           the container's HOME, on the host
                       (default: \$XDG_DATA_HOME/claude-container/home)

Session
  --skip-permissions   pass --dangerously-skip-permissions to claude; the
                       container is the sandbox, so this is the point of it
  --shell              drop into bash instead of starting claude
  --no-auth            do not seed credentials from your host ~/.claude
  --ssh-agent          forward \$SSH_AUTH_SOCK in (for git push)
  --env NAME[=VALUE]   pass an environment variable through (repeatable)

Container
  --ephemeral          no /nix volume; Claude's installs die with the container
  --runtime NAME       podman or docker (default: whichever is on PATH;
                       override with \$CLAUDE_CONTAINER_RUNTIME)
  --runtime-arg ARG    extra argument for \`run\` (repeatable)
  --reload             load the image again even if it is already present
  --prune              remove images and /nix volumes from older builds, then exit
  -v, --verbose        print the container command before running it
  -h, --help           show this

Image: $image_ref
EOF
}

need_arg() {
    [ "$2" -ge 2 ] || die "$1 needs an argument"
}

ro=0 shell=0 seed_auth=1 ssh_agent=0 ephemeral=0 reload=0 prune=0 verbose=0
skip_perms=0
runtime="" home="$default_home"
dirs=() extra_rw=() extra_ro=() user_envs=() runtime_args=() claude_args=()

while [ "$#" -gt 0 ]; do
    case "$1" in
    --ro | --read-only) ro=1; shift ;;
    --mount) need_arg "$1" "$#"; extra_rw+=("$2"); shift 2 ;;
    --mount=*) extra_rw+=("${1#--mount=}"); shift ;;
    --mount-ro) need_arg "$1" "$#"; extra_ro+=("$2"); shift 2 ;;
    --mount-ro=*) extra_ro+=("${1#--mount-ro=}"); shift ;;
    --home) need_arg "$1" "$#"; home="$2"; shift 2 ;;
    --home=*) home="${1#--home=}"; shift ;;
    --skip-permissions | --yolo) skip_perms=1; shift ;;
    --shell) shell=1; shift ;;
    --no-auth) seed_auth=0; shift ;;
    --ssh-agent) ssh_agent=1; shift ;;
    --env) need_arg "$1" "$#"; user_envs+=("$2"); shift 2 ;;
    --env=*) user_envs+=("${1#--env=}"); shift ;;
    --ephemeral) ephemeral=1; shift ;;
    --runtime) need_arg "$1" "$#"; runtime="$2"; shift 2 ;;
    --runtime=*) runtime="${1#--runtime=}"; shift ;;
    --runtime-arg) need_arg "$1" "$#"; runtime_args+=("$2"); shift 2 ;;
    --runtime-arg=*) runtime_args+=("${1#--runtime-arg=}"); shift ;;
    --reload) reload=1; shift ;;
    --prune) prune=1; shift ;;
    -v | --verbose) verbose=1; shift ;;
    -h | --help) usage; exit 0 ;;
    --) shift; claude_args+=("$@"); break ;;
    -*) printf '%s: unknown option: %s\n\n' "$prog" "$1" >&2; usage >&2; exit 2 ;;
    *) dirs+=("$1"); shift ;;
    esac
done

# ---- the runtime --------------------------------------------------------
if [ -z "$runtime" ]; then
    runtime="${CLAUDE_CONTAINER_RUNTIME:-}"
fi
if [ -z "$runtime" ]; then
    if command -v podman >/dev/null 2>&1; then
        runtime=podman
    elif command -v docker >/dev/null 2>&1; then
        runtime=docker
    else
        die "no podman or docker on PATH"
    fi
fi
command -v "$runtime" >/dev/null 2>&1 || die "runtime not found: $runtime"

# Does container uid 0 mean *you*? If it does, the container can run as root
# -- it owns /nix and still writes your files as you. If it does not, the
# entrypoint has to drop to your uid, and take /nix with it.
rootless=0
case "$(basename "$runtime")" in
*podman*)
    if [ "$("$runtime" info --format '{{.Host.Security.Rootless}}' 2>/dev/null || true)" = true ]; then
        rootless=1
    fi
    ;;
*docker*)
    if "$runtime" info --format '{{range .SecurityOptions}}{{println .}}{{end}}' 2>/dev/null |
        grep -q 'name=rootless'; then
        rootless=1
    fi
    ;;
esac

if [ "$rootless" = 1 ]; then
    cc_uid=0 cc_gid=0
else
    cc_uid="$(id -u)" cc_gid="$(id -g)"
fi

# ---- --prune ------------------------------------------------------------
if [ "$prune" = 1 ]; then
    stale_images=() stale_volumes=()
    mapfile -t stale_images < <(
        "$runtime" images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null |
            grep "^$image_name:" | grep -vx "$image_ref" || true
    )
    mapfile -t stale_volumes < <(
        "$runtime" volume ls --format '{{.Name}}' 2>/dev/null |
            grep '^claude-container-nix-' | grep -vx "$nix_volume" || true
    )
    if [ "${#stale_images[@]}" -eq 0 ] && [ "${#stale_volumes[@]}" -eq 0 ]; then
        note "nothing stale; $image_ref and $nix_volume are current"
        exit 0
    fi
    for i in "${stale_images[@]}"; do
        note "removing image $i"
        "$runtime" rmi "$i" || true
    done
    for v in "${stale_volumes[@]}"; do
        note "removing volume $v"
        "$runtime" volume rm "$v" || true
    done
    exit 0
fi

# ---- what to mount ------------------------------------------------------
if [ "${#dirs[@]}" -eq 0 ]; then
    dirs=("$PWD")
fi

mounts=()

# Prints the path it resolved, so it cannot append to `mounts` itself -- a
# command substitution runs in a subshell. `die` in here only kills that
# subshell, but the failed assignment trips `set -e` in the caller.
resolve_dir() {
    local path
    path="$(realpath -e -- "$1" 2>/dev/null)" || die "no such directory: $1"
    [ -d "$path" ] || die "not a directory: $1"
    [ "$path" != / ] || die "refusing to mount / -- name a project directory"
    printf '%s' "$path"
}

workdir=""
workspace_mode=rw
if [ "$ro" = 1 ]; then
    workspace_mode=ro
fi
for d in "${dirs[@]}"; do
    path="$(resolve_dir "$d")"
    if [ "$workspace_mode" = ro ]; then
        mounts+=(--volume "$path:$path:ro")
    else
        mounts+=(--volume "$path:$path")
    fi
    [ -n "$workdir" ] || workdir="$path"
done
for d in "${extra_rw[@]}"; do
    path="$(resolve_dir "$d")"
    mounts+=(--volume "$path:$path")
done
for d in "${extra_ro[@]}"; do
    path="$(resolve_dir "$d")"
    mounts+=(--volume "$path:$path:ro")
done

if [ "$workdir" = "${HOME%/}" ]; then
    warn "mounting your entire home directory $workspace_mode"
fi

# A container name that says what it was about at a glance: the basename of
# the mounted directory, sanitized to what docker/podman accept in --name.
project_slug="$(basename -- "$workdir" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9_.-]+/-/g; s/^-+//; s/-+$//')"
[ -n "$project_slug" ] || project_slug="dir"
container_name="claude-$project_slug-$$"

# ---- the container's own home -------------------------------------------
mkdir -p "$home"
home="$(realpath -e -- "$home")"
mounts+=(--volume "$home:$container_home")

# Seeded, not shared: Claude in here logs in as you without being able to
# touch the host's ~/.claude. Delete the copy to force a fresh /login.
if [ "$seed_auth" = 1 ] &&
    [ ! -e "$home/.claude/.credentials.json" ] &&
    [ -f "$HOME/.claude/.credentials.json" ]; then
    mkdir -p "$home/.claude"
    install -m 600 "$HOME/.claude/.credentials.json" "$home/.claude/.credentials.json"
    note "seeded credentials into $home/.claude"
fi
if [ ! -e "$home/.claude/.credentials.json" ] &&
    [ -z "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}" ]; then
    note "no credentials in $home -- run /login inside the container"
fi

# Your git identity, read-only, so Claude commits as you but cannot rewrite
# who you are. Both locations are checked because home-manager writes
# programs.git to ~/.config/git/config, not ~/.gitconfig -- see the note on
# precedence in home/core.nix. Mounting the XDG path works even though it is
# a symlink into the store: a bind mount resolves it host-side.
git_xdg="${XDG_CONFIG_HOME:-$HOME/.config}/git/config"
if [ -f "$HOME/.gitconfig" ]; then
    mounts+=(--volume "$HOME/.gitconfig:$container_home/.gitconfig:ro")
elif [ -f "$git_xdg" ]; then
    mounts+=(--volume "$git_xdg:$container_home/.config/git/config:ro")
fi

if [ "$ephemeral" = 0 ]; then
    mounts+=(--volume "$nix_volume:/nix")
elif [ "$rootless" = 0 ]; then
    warn "--ephemeral on a rootful $runtime: /nix gets chowned on every start, which is slow"
fi

if [ "$ssh_agent" = 1 ]; then
    [ -n "${SSH_AUTH_SOCK:-}" ] || die "--ssh-agent given but \$SSH_AUTH_SOCK is unset"
    mounts+=(--volume "$SSH_AUTH_SOCK:/run/ssh-agent.sock")
fi

# ---- environment --------------------------------------------------------
env_args=(--env "CC_UID=$cc_uid" --env "CC_GID=$cc_gid")
if [ "$ssh_agent" = 1 ]; then
    env_args+=(--env "SSH_AUTH_SOCK=/run/ssh-agent.sock")
fi
# `--env NAME` with no value means "take it from my environment", which keeps
# secrets off this process's command line.
for name in \
    TERM COLORTERM \
    ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL \
    ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL \
    ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL \
    ANTHROPIC_DEFAULT_HAIKU_MODEL \
    CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX \
    HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy; do
    if [ -n "${!name:-}" ]; then
        env_args+=(--env "$name")
    fi
done
for e in "${user_envs[@]}"; do
    env_args+=(--env "$e")
done

# ---- load the image on first use ----------------------------------------
if [ "$reload" = 1 ] || ! "$runtime" image inspect "$image_ref" >/dev/null 2>&1; then
    note "loading $image_ref"
    "$image_streamer" | "$runtime" load
fi

# ---- run ----------------------------------------------------------------
tty_args=(--interactive)
if [ -t 0 ] && [ -t 1 ]; then
    tty_args+=(--tty)
fi

if [ "$shell" = 1 ]; then
    cmd=(bash)
else
    cmd=(claude)
    if [ "$skip_perms" = 1 ]; then
        cmd+=(--dangerously-skip-permissions)
    fi
    cmd+=("${claude_args[@]}")
fi

run=(
    "$runtime" run --rm --init
    --hostname claude-container
    --name "$container_name"
    --workdir "$workdir"
    "${tty_args[@]}"
    "${mounts[@]}"
    "${env_args[@]}"
    "${runtime_args[@]}"
    "$image_ref"
    "${cmd[@]}"
)

if [ "$verbose" = 1 ]; then
    printf '%s%s:%s' "$dim" "$prog" "$reset" >&2
    printf ' %q' "${run[@]}" >&2
    printf '\n' >&2
fi

exec "${run[@]}"
