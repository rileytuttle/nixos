#!/usr/bin/env bash
#
# Hand the niri/DMS dotfile paths back to home-manager on rt-dellpromax-24.
#
# Context: the configs that used to live in a separate dotfiles repo
# (~/Configs) now live in this one, delivered by home-manager rather than by
# hand-made symlinks. When that repo went away the old links were left
# behind, and whatever they are now decides what home-manager does next:
#
#   dangling symlink   -> harmless. linkGeneration relinks it with `ln -f -n`.
#   live foreign link  -> FATAL. checkLinkTargets aborts the whole switch
#   regular file/dir   -> FATAL.  with "Existing file ... would be clobbered".
#   parent dir is a    -> FATAL, and the error names the *file*, not the
#     symlink                     directory, so it reads as a puzzle.
#
# That last one is the usual dotfiles-repo shape (~/.config/niri as a whole
# symlinked directory) and the one worth having a tool for. Any of the three
# fatal cases makes `home-manager switch` exit non-zero having changed
# nothing -- so ~/.config/niri/config.kdl, the DMS settings, the
# environment.d PATH file and the ~/.local/bin/dms nixGL shim all stay
# missing, and niri comes up with no bar.
#
# So this does NOT symlink anything into ~/nixos. Pointing a path at the
# repo by hand is exactly the collision described above, and it would break
# `home-manager switch` permanently. It clears the way and lets
# home-manager own the paths, which is what the flake already declares.
#
# Read-only unless you pass --apply. The paths come from the flake itself
# (`nix eval` on home.file), so this list cannot drift out of sync with
# home/niri.nix, home/dank-material-shell.nix or home/niri-generic-linux.nix.
#
# Usage:
#   ./scripts/relink-dotfiles.sh                 # report only
#   ./scripts/relink-dotfiles.sh --apply         # move blockers aside
#   ./scripts/relink-dotfiles.sh --apply --switch  # ...then switch
#   ./scripts/relink-dotfiles.sh --all           # every managed path,
#                                                #   not just niri/DMS
#   ./scripts/relink-dotfiles.sh --host NAME     # default rt-dellpromax-24
#
set -uo pipefail

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="rt-dellpromax-24"
APPLY=0
SWITCH=0
SCOPE="niri"

# The niri/DMS subset of the managed paths. Everything the bar needs to come
# up is in here: the niri config that spawns dms, the DMS settings, the
# environment.d file that puts ~/.nix-profile/bin on niri's PATH, the
# ~/.local/bin/dms nixGL shim, the fontconfig files DMS's Material Symbols
# font needs, and the polkit agent unit.
NIRI_RE='(^|/)(niri|DankMaterialShell)/|/environment\.d/|/fontconfig/|\.local/bin/dms$|polkit-gnome|toggle-kakoune'

# Only consulted when `nix eval` cannot run (offline, broken flake -- i.e.
# exactly when you are already debugging something). Kept deliberately
# short: these are the paths whose absence shows up as "no bar".
FALLBACK_TARGETS=(
    ".config/niri/config.kdl"
    ".config/DankMaterialShell/settings.json"
    ".config/environment.d/95-nix-profile.conf"
    ".config/environment.d/10-home-manager.conf"
    ".local/bin/dms"
)

ok()    { printf '  \033[32mok\033[0m      %s\n' "$*"; }
bad()   { printf '  \033[31mBLOCK\033[0m   %s\n' "$*"; }
stale() { printf '  \033[33mstale\033[0m   %s\n' "$*"; }
miss()  { printf '  \033[36mmissing\033[0m %s\n' "$*"; }
note()  { printf '          %s\n' "$*"; }
head_() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }

usage() { sed -n '2,/^set -uo/p' "$0" | sed 's/^#\{1,2\} \{0,1\}//; s/^#$//' | head -n -1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --apply)  APPLY=1 ;;
        --switch) SWITCH=1 ;;
        --all)    SCOPE="all" ;;
        --host)   HOST="${2:?--host needs a value}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'unknown argument: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[ "$SWITCH" = 1 ] && [ "$APPLY" = 0 ] && {
    printf '--switch without --apply would switch into the same collisions.\n' >&2
    printf 'Add --apply, or run home-manager switch yourself.\n' >&2
    exit 2
}

# --- 1. what does the flake claim? -----------------------------------------

head_ "1. paths home-manager owns (#$HOST)"

TARGETS=()
EVAL_OUT="$(nix eval --json \
    "${REPO}#homeConfigurations.${HOST}.config.home.file" \
    --apply 'fs: builtins.map (v: v.target) (builtins.attrValues fs)' 2>&1)"

# A successful eval prints a JSON array; any failure prints a nix error, so
# the first character is the whole test. ($? would have to be read before
# the `[` below runs, and that reads worse than this does.)
if [ "${EVAL_OUT:0:1}" = "[" ]; then
    while IFS= read -r t; do
        [ -n "$t" ] && TARGETS+=("$t")
    done < <(printf '%s' "$EVAL_OUT" | tr -d '[]"' | tr ',' '\n')
    note "derived ${#TARGETS[@]} managed paths from the flake"
else
    printf '  \033[33mwarn\033[0m    nix eval failed; using the built-in fallback list,\n'
    note "which may be out of date. The error was:"
    printf '%s\n' "$EVAL_OUT" | sed 's/^/          | /' | tail -5
    TARGETS=("${FALLBACK_TARGETS[@]}")
fi

# Filter to scope.
SELECTED=()
for t in "${TARGETS[@]}"; do
    if [ "$SCOPE" = "all" ] || [[ "$t" =~ $NIRI_RE ]]; then
        SELECTED+=("$t")
    fi
done
note "checking ${#SELECTED[@]} of them (scope: $SCOPE)"

[ ${#SELECTED[@]} -eq 0 ] && { printf '\nNothing to check.\n'; exit 0; }

# --- 2. classify ------------------------------------------------------------
#
# Mirrors modules/files/check-link-targets.sh and the linkGeneration script
# in home-manager's modules/files.nix. A symlink into
# /nix/store/*-home-manager-files/* is ours; anything else that *resolves*
# is a collision.

head_ "2. current state"

HM_PATTERN='/nix/store/*-home-manager-files/*'
BLOCKERS=()      # paths to move
BLOCK_WHY=()
STALE=()

# Ancestors of a target, below $HOME, outermost first. A symlinked ancestor
# is checked once even when several targets share it.
declare -A DIR_SEEN=()

classify_dirs() {
    local rel="$1" acc=""
    local IFS=/
    read -ra parts <<< "$(dirname -- "$rel")"
    [ "$(dirname -- "$rel")" = "." ] && return
    for p in "${parts[@]}"; do
        acc="${acc:+$acc/}$p"
        [ -n "${DIR_SEEN[$acc]:-}" ] && continue
        DIR_SEEN[$acc]=1
        local abs="$HOME/$acc"
        if [ -L "$abs" ]; then
            local dest; dest="$(readlink -- "$abs")"
            if [ -e "$abs" ]; then
                bad "$acc/ is a SYMLINK -> $dest"
                note "A symlinked parent directory breaks linkGeneration for"
                note "every file under it. This is the classic dotfiles-repo"
                note "layout and the most likely cause here."
                BLOCKERS+=("$acc"); BLOCK_WHY+=("directory symlink -> $dest")
            else
                bad "$acc/ is a DANGLING symlink -> $dest"
                note "Points nowhere, but home-manager still cannot mkdir"
                note "through it, so the files under it never get written."
                BLOCKERS+=("$acc"); BLOCK_WHY+=("dangling directory symlink -> $dest")
            fi
        fi
    done
}

for rel in "${SELECTED[@]}"; do
    classify_dirs "$rel"
done

for rel in "${SELECTED[@]}"; do
    abs="$HOME/$rel"

    # Skip files whose parent is already flagged; moving the directory
    # takes them with it.
    skip=""
    for b in "${BLOCKERS[@]}"; do
        [[ "$rel" == "$b"/* ]] && { skip=1; break; }
    done
    [ -n "$skip" ] && continue

    if [ -L "$abs" ]; then
        dest="$(readlink -- "$abs")"
        if [[ "$dest" == $HM_PATTERN ]]; then
            ok "$rel"
        elif [ ! -e "$abs" ]; then
            stale "$rel -> $dest (dangling)"
            STALE+=("$rel")
        else
            bad "$rel -> $dest"
            note "Resolves, and is not ours: checkLinkTargets aborts the switch."
            BLOCKERS+=("$rel"); BLOCK_WHY+=("foreign symlink -> $dest")
        fi
    elif [ -e "$abs" ]; then
        kind="regular file"; [ -d "$abs" ] && kind="directory"
        bad "$rel ($kind, not a symlink)"
        BLOCKERS+=("$rel"); BLOCK_WHY+=("$kind in the way")
    else
        miss "$rel"
    fi
done

# --- 3. act -----------------------------------------------------------------

head_ "3. $([ "$APPLY" = 1 ] && echo 'moving blockers aside' || echo 'what --apply would do')"

if [ ${#BLOCKERS[@]} -eq 0 ] && [ ${#STALE[@]} -eq 0 ]; then
    ok "nothing in the way"
else
    BACKUP="$HOME/.local/state/relink-dotfiles/$(date +%Y%m%d-%H%M%S)"
    note "backup root: $BACKUP"
    note ""

    for i in "${!BLOCKERS[@]}"; do
        rel="${BLOCKERS[i]}"; why="${BLOCK_WHY[i]}"
        abs="$HOME/$rel"

        # A moved directory takes unmanaged files with it. ~/.config/niri in
        # particular is meant to hold a hand-edited local.kdl that this repo
        # deliberately does not manage (see home/niri-generic-linux.nix), so
        # name what is going along for the ride.
        carried=""
        if [ -d "$abs" ]; then
            carried="$(find -L "$abs" -maxdepth 1 -type f -printf '%P\n' 2>/dev/null | head -20)"
        fi

        if [ "$APPLY" = 1 ]; then
            mkdir -p -- "$BACKUP/$(dirname -- "$rel")" || exit 1
            mv -- "$abs" "$BACKUP/$rel" || exit 1
            printf '  moved   %s\n' "$rel"
        else
            printf '  would move  %s\n' "$rel"
        fi
        note "($why)"
        if [ -n "$carried" ]; then
            note "carries these unmanaged files with it -- copy back what you want:"
            printf '%s\n' "$carried" | sed 's/^/          | /'
        fi
    done

    for rel in "${STALE[@]}"; do
        abs="$HOME/$rel"
        if [ "$APPLY" = 1 ]; then
            mkdir -p -- "$BACKUP/$(dirname -- "$rel")" || exit 1
            mv -- "$abs" "$BACKUP/$rel" || exit 1
            printf '  moved   %s (dangling; switch would have replaced it anyway)\n' "$rel"
        else
            printf '  would move  %s (dangling; harmless either way)\n' "$rel"
        fi
    done
fi

# --- 4. switch --------------------------------------------------------------

head_ "4. next"

if [ "$SWITCH" = 1 ]; then
    note "running: home-manager switch --flake ${REPO}#${HOST}"
    note ""
    home-manager switch --flake "${REPO}#${HOST}" || {
        printf '\n  switch failed -- re-run this script to see what is still in the way.\n'
        exit 1
    }
    printf '\n'
    ok "switch completed"
elif [ "$APPLY" = 1 ]; then
    note "Now run:  home-manager switch --flake ${REPO}#${HOST}"
else
    note "Re-run with --apply to move the blockers, or --apply --switch to"
    note "move them and switch in one go."
fi

note ""
note "Then LOG FULLY OUT and back in, not just restart niri."
note "~/.config/environment.d/95-nix-profile.conf is read when the systemd"
note "*user manager* starts. Until that happens niri's PATH has no"
note "~/.nix-profile/bin, spawn-at-startup \"dms\" \"run\" resolves nothing,"
note "and there is still no bar."
note ""
note "If the bar is still missing after that: ./scripts/debug-dms-bar.sh"
echo
