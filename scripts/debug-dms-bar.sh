#!/usr/bin/env bash
#
# Diagnose a missing DankMaterialShell bar on rt-dellpromax-24.
#
# The bar is DMS, which is NOT started by systemd on this host
# (home/dank-material-shell.nix sets systemd.enable = false). It is started
# by the `spawn-at-startup "dms" "run"` line in home/niri-config.kdl, so the
# whole chain that has to work is:
#
#   gdm -> niri.desktop -> niri-session -> niri.service (systemd user unit)
#       -> systemd merges ~/.config/environment.d/95-nix-profile.conf into PATH
#       -> niri spawns `dms run`, found in ~/.nix-profile/bin
#       -> dms launches quickshell, a nix-built Qt6/QML GPU client on Ubuntu
#
# Any link in that chain breaks silently and the only symptom is "no bar".
# This script is read-only: it inspects, it never changes anything.
#
# Run it from inside the niri session (a terminal on the niri desktop), or
# the session-dependent checks will be skipped.
#
# Usage:
#   ./scripts/debug-dms-bar.sh
#
set -uo pipefail

PROFILE_BIN="${HOME}/.nix-profile/bin"
ENV_D="${HOME}/.config/environment.d/95-nix-profile.conf"
NIRI_CFG="${HOME}/.config/niri/config.kdl"

ok()    { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad()   { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAILURES+=("$*"); }
warn()  { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
note()  { printf '        %s\n' "$*"; }
head_() { printf '\n\033[36m==> %s\033[0m\n' "$*"; }

# procps is not guaranteed on a minimal install, so fall back to ps.
proc_pid()  { if command -v pgrep >/dev/null; then pgrep -x "$1" | head -1
              else ps -eo pid=,comm= 2>/dev/null | awk -v c="$1" '$2==c{print $1; exit}'; fi; }
proc_list() { if command -v pgrep >/dev/null; then pgrep -af "$1"
              else ps -eo pid=,args= 2>/dev/null | grep -E "$1" | grep -v grep; fi; }

FAILURES=()

case "${1:-}" in
    -h|--help) sed -n '2,/^set -uo/p' "$0" | sed 's/^#\{1,2\} \{0,1\}//; s/^#$//' | head -n -1; exit 0 ;;
esac

# --- 1. are we actually in the niri session? -------------------------------

head_ "1. session"

NIRI_PID="$(proc_pid niri)"
if [ -n "$NIRI_PID" ]; then
    ok "niri is running (pid $NIRI_PID)"
else
    bad "no niri process found — are you logged into the niri session?"
fi

if [ -n "${WAYLAND_DISPLAY:-}" ]; then
    ok "WAYLAND_DISPLAY=$WAYLAND_DISPLAY  XDG_CURRENT_DESKTOP=${XDG_CURRENT_DESKTOP:-unset}"
    IN_SESSION=1
else
    warn "WAYLAND_DISPLAY unset — this shell is not inside the Wayland session."
    note "Session-dependent checks below will be unreliable. Re-run from a"
    note "terminal opened inside niri (Mod+T)."
    IN_SESSION=0
fi

if [ -n "$NIRI_PID" ]; then
    if systemctl --user is-active --quiet niri.service; then
        ok "niri is running as niri.service (systemd user unit) — environment.d applies"
    else
        bad "niri is running, but NOT as niri.service"
        note "environment.d is only merged into services systemd starts. If gdm"
        note "execs the niri binary directly instead of going through"
        note "niri-session, PATH never picks up ~/.nix-profile/bin and every"
        note "spawn-at-startup silently fails. Check that"
        note "/usr/local/share/wayland-sessions/niri.desktop has Exec=niri-session."
    fi
fi

# --- 2. is dms even installed? ---------------------------------------------

head_ "2. dms installation (home-manager)"

if [ -x "$PROFILE_BIN/dms" ]; then
    ok "$PROFILE_BIN/dms exists"
else
    bad "$PROFILE_BIN/dms is missing — home-manager switch has not applied DMS"
    note "Run: home-manager switch --flake .#rt-dellpromax-24"
fi

for qs in qs quickshell; do
    [ -x "$PROFILE_BIN/$qs" ] && ok "$PROFILE_BIN/$qs exists (DMS renders through quickshell)"
done
[ -x "$PROFILE_BIN/qs" ] || [ -x "$PROFILE_BIN/quickshell" ] || \
    bad "neither qs nor quickshell in $PROFILE_BIN — DMS has no renderer"

if [ -e "$ENV_D" ]; then
    ok "$ENV_D exists"
    sed 's/^/        | /' "$ENV_D"
else
    bad "$ENV_D missing — home/niri-generic-linux.nix has not been applied"
fi

# --- 3. is dms running right now? ------------------------------------------

head_ "3. dms process"

DMS_PROCS="$(proc_list 'dms|quickshell' | grep -v debug-dms-bar || true)"
if [ -n "$DMS_PROCS" ]; then
    ok "something DMS-ish is running:"
    printf '        | %s\n' "$DMS_PROCS"
    note "If these are alive but there is still no bar, the problem is DMS"
    note "rendering (section 6), not spawning."
else
    bad "no dms/quickshell process — the spawn-at-startup never produced a live bar"
fi

# --- 4. the PATH niri actually has -----------------------------------------

head_ "4. PATH inside the niri process"

if [ -n "$NIRI_PID" ] && [ -r "/proc/$NIRI_PID/environ" ]; then
    NIRI_PATH="$(tr '\0' '\n' < "/proc/$NIRI_PID/environ" | sed -n 's/^PATH=//p')"
    note "PATH=$NIRI_PATH"
    case ":$NIRI_PATH:" in
        *":$PROFILE_BIN:"*)
            ok "~/.nix-profile/bin is on niri's PATH — spawn \"dms\" can resolve" ;;
        *)
            bad "~/.nix-profile/bin is NOT on niri's PATH"
            note "This is the single most likely cause of a missing bar."
            note "environment.d is read when the systemd user manager starts. If"
            note "you ran home-manager switch while already logged in, the running"
            note "manager predates the file. Log fully out and back in (or reboot)."
            ;;
    esac
else
    warn "cannot read niri's environment (no pid, or not your process)"
fi

if MGR_PATH="$(systemctl --user show-environment 2>/dev/null | sed -n 's/^PATH=//p')"; then
    case ":$MGR_PATH:" in
        *":$PROFILE_BIN:"*) ok "systemd user manager env also has ~/.nix-profile/bin" ;;
        *) warn "systemd user manager PATH lacks ~/.nix-profile/bin: $MGR_PATH" ;;
    esac
fi

# --- 5. what niri logged ---------------------------------------------------

head_ "5. niri log (spawn failures)"

LOG="$(journalctl --user -u niri.service -b --no-pager 2>/dev/null \
        | grep -iE 'dms|spawn|failed|error|panic' | tail -30)"
if [ -n "$LOG" ]; then
    printf '        | %s\n' "$LOG"
    note ""
    note "A line like 'error spawning process' / 'No such file or directory'"
    note "for dms confirms the PATH problem in section 4."
else
    note "nothing matching in this boot's niri.service journal."
    note "If niri is not running as a service, try instead:"
    note "  journalctl --user -b --no-pager | grep -i niri | tail -40"
fi

# --- 6. can dms actually render? (the nixGL question) ----------------------

head_ "6. GPU / quickshell rendering"

GPU="$(lspci 2>/dev/null | grep -iE 'vga|3d controller' || echo 'unknown')"
printf '        | %s\n' "$GPU"

if [ -d /sys/module/nvidia ]; then
    warn "NVIDIA proprietary driver is loaded."
    note "quickshell comes from nix and links nix's libEGL/libGL, which cannot"
    note "load Ubuntu's NVIDIA driver. This is the case README.md flags as"
    note "needing nixGL. DMS will start and then die, or show a blank bar."
else
    ok "no NVIDIA kernel module — Intel/AMD mesa, which usually works unwrapped"
fi

if [ "$IN_SESSION" = 1 ] && [ -x "$PROFILE_BIN/dms" ]; then
    note ""
    note "Live render test — this is the most informative single check.  Run it"
    note "in a niri terminal and read the errors it prints:"
    note ""
    note "    dms run"
    note ""
    note "  'Failed to create OpenGL context' / 'eglInitialize' => nixGL case."
    note "  'command not found'                                 => PATH case."
    note "  starts clean and a bar appears                      => spawn-at-startup"
    note "                                                         timing, not DMS."
fi

# --- 6b. narrow it down: DMS-specific, or every nix spawn? ------------------
#
# The keybinds in home/niri-config.kdl split cleanly by where the binary
# lives, which makes them a free bisect:
#
#   Mod+T -> gnome-terminal  (apt, /usr/bin)          -- niri itself is fine
#   Mod+D -> fuzzel          (nix, ~/.nix-profile/bin) -- PATH is fine
#   Mod+Space -> dms ipc ... (nix, AND needs live DMS) -- DMS is fine
#
# Note that Mod+Space does not launch anything: `dms ipc spotlight toggle`
# only talks to an already-running DMS. There is no separate spotlight to
# install — no bar and no launcher are one symptom, not two.

head_ "6b. bisect with the keybinds"

note "Press these in niri, in order, and stop at the first that does nothing:"
note ""
note "  Mod+T      gnome-terminal   apt binary in /usr/bin"
note "  Mod+D      fuzzel           nix binary in ~/.nix-profile/bin"
note "  Mod+Space  dms spotlight    IPC into the running DMS process"
note ""
note "  all three dead      -> niri is not reading this config (section 7)"
note "  only Mod+T works    -> PATH problem (section 4); nix spawns can't resolve"
note "  T+D work, Space not -> PATH is fine, DMS itself is not running (section 6)"
note ""
note "Mod+Space is NOT a separate program. It toggles a panel inside the DMS"
note "process, so a missing bar and a dead launcher have the same root cause:"
note "DMS is not running. Fix the bar and the launcher returns with it."

# --- 7. config sanity ------------------------------------------------------

head_ "7. niri config"

if [ -e "$NIRI_CFG" ]; then
    ok "$NIRI_CFG exists -> $(readlink -f "$NIRI_CFG")"
    if command -v niri >/dev/null; then
        if niri validate -c "$NIRI_CFG" >/dev/null 2>&1; then
            ok "niri validate passes ($(niri --version 2>/dev/null))"
        else
            bad "niri validate FAILS — niri may be ignoring the config entirely"
            niri validate -c "$NIRI_CFG" 2>&1 | sed 's/^/        | /'
        fi
    else
        warn "niri not on this shell's PATH; skipping validate"
    fi
    if grep -q 'spawn-at-startup "dms" "run"' "$NIRI_CFG"; then
        ok 'config contains spawn-at-startup "dms" "run"'
    else
        bad 'config does NOT contain the dms spawn-at-startup line'
    fi
else
    bad "$NIRI_CFG missing — home-manager has not delivered the niri config"
fi

# --- summary ---------------------------------------------------------------

head_ "summary"
if [ ${#FAILURES[@]} -eq 0 ]; then
    printf '  No failed checks. If the bar is still missing, run `dms run` by hand\n'
    printf '  (section 6) and read its stderr.\n'
else
    printf '  %d failed check(s), in the order they break the chain:\n\n' "${#FAILURES[@]}"
    printf '   - %s\n' "${FAILURES[@]}"
    printf '\n  Fix the first one listed; later ones are usually consequences.\n'
fi
echo
