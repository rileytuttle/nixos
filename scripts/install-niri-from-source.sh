#!/usr/bin/env bash
#
# Build niri from source and install it system-wide on a non-NixOS Debian/
# Ubuntu host (rt-dellpromax-24).
#
# Why from source: home/niri-config.kdl ends with
# `include optional=true "local.kdl"`. Per niri's docs `include` landed in
# niri 25.11 and the `optional=true` parameter only in 26.04, and no Ubuntu 24
# release ships anything close (24.04 has no niri package at all).
#
# Why system-wide: gdm builds its session list before anyone logs in, running
# as the `gdm` user, so it cannot read $HOME. Nothing home-manager writes can
# ever appear in the session picker — the .desktop file has to live in a
# system path. Everything here installs under $PREFIX (default /usr/local),
# which is also why this is the one imperative piece of this host's setup.
#
# Safe to re-run; it updates an existing checkout rather than recloning.
#
# Usage:
#   ./scripts/install-niri-from-source.sh                  # latest release tag
#   ./scripts/install-niri-from-source.sh --ref v26.04     # a specific tag
#   ./scripts/install-niri-from-source.sh --skip-deps      # skip apt + rustup
#
set -euo pipefail

REPO_URL="https://github.com/niri-wm/niri.git"
SRC_DIR="${HOME}/src/niri"
PREFIX="/usr/local"
REF=""
SKIP_DEPS=0
# Floor required by home/niri-config.kdl's `include optional=true`.
MIN_VERSION="26.04"

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed 's/^#\{1,2\} \{0,1\}//; s/^#$//' | head -n -1
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ref)       REF="${2:?--ref needs a value}"; shift 2 ;;
        --src-dir)   SRC_DIR="${2:?--src-dir needs a value}"; shift 2 ;;
        --prefix)    PREFIX="${2:?--prefix needs a value}"; shift 2 ;;
        --skip-deps) SKIP_DEPS=1; shift ;;
        -h|--help)   usage ;;
        *)           die "unknown argument: $1 (try --help)" ;;
    esac
done

# --- preflight -------------------------------------------------------------

[ "$(id -u)" -ne 0 ] || die "do not run this as root; it builds as you and uses sudo only to install"
command -v apt-get >/dev/null || die "this script targets Debian/Ubuntu (no apt-get found)"
command -v sudo    >/dev/null || die "sudo is required"

info "asking for sudo up front so the build isn't interrupted later"
sudo -v || die "could not obtain sudo"

# Keep the sudo timestamp warm for the duration of the build.
while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
SUDO_KEEPALIVE=$!
trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null || true' EXIT

# --- build dependencies ----------------------------------------------------

if [ "$SKIP_DEPS" -eq 0 ]; then
    info "installing build dependencies (niri's own list for Ubuntu 24.04)"
    sudo apt-get update
    sudo apt-get install -y \
        git curl ca-certificates \
        gcc clang libudev-dev libgbm-dev libxkbcommon-dev libegl1-mesa-dev \
        libwayland-dev libinput-dev libdbus-1-dev libsystemd-dev libseat-dev \
        libpipewire-0.3-dev libpango1.0-dev libdisplay-info-dev

    # Runtime bits the niri config's keybinds and spawns rely on. Taken from
    # apt rather than nix so they match the running system.
    info "installing runtime dependencies referenced by home/niri-config.kdl"
    sudo apt-get install -y \
        gnome-terminal wireplumber playerctl xdg-desktop-portal-gnome || \
        warn "some runtime packages failed to install; check the names for your release"

    # Needed for X11 apps under niri. Not present in every Ubuntu release, so
    # it's attempted separately rather than failing the batch above.
    sudo apt-get install -y xwayland-satellite || {
        warn "xwayland-satellite not available from apt; X11 apps won't work until"
        warn "  you install it another way (nix, or build it from source too)"
    }
fi

# --- rust ------------------------------------------------------------------

if [ "$SKIP_DEPS" -eq 0 ]; then
    if command -v rustup >/dev/null; then
        info "updating rust stable via rustup"
        rustup update stable
    else
        info "installing rustup (Ubuntu 24.04's packaged rustc is too old for niri)"
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
    fi
fi

# rustup installs here and we may not have restarted the shell.
[ -f "${HOME}/.cargo/env" ] && . "${HOME}/.cargo/env"
command -v cargo >/dev/null || die "cargo not on PATH; open a new shell or source ~/.cargo/env"
info "using $(cargo --version)"

# --- source ----------------------------------------------------------------

if [ -d "${SRC_DIR}/.git" ]; then
    info "updating existing checkout at ${SRC_DIR}"
    git -C "$SRC_DIR" fetch --tags --prune origin
else
    info "cloning niri into ${SRC_DIR}"
    mkdir -p "$(dirname "$SRC_DIR")"
    git clone "$REPO_URL" "$SRC_DIR"
fi

if [ -z "$REF" ]; then
    REF="$(git -C "$SRC_DIR" tag -l 'v[0-9]*' | sort -V | tail -1)"
    [ -n "$REF" ] || die "could not determine the latest release tag; pass --ref explicitly"
    info "latest release tag is ${REF}"
fi

info "checking out ${REF}"
git -C "$SRC_DIR" checkout --quiet --detach "$REF"

# Warn early if the chosen ref predates the config's requirements, rather than
# after a long build.
REF_VERSION="${REF#v}"
if [ "$(printf '%s\n%s\n' "$MIN_VERSION" "$REF_VERSION" | sort -V | head -1)" != "$MIN_VERSION" ]; then
    warn "${REF} is older than ${MIN_VERSION}; home/niri-config.kdl uses"
    warn "  \`include optional=true\`, which needs niri ${MIN_VERSION}+. The config will"
    warn "  likely fail to parse. Re-run with --ref pointing at a newer tag."
fi

# --- build -----------------------------------------------------------------

info "building (this takes a while on a cold cargo cache)"
( cd "$SRC_DIR" && cargo build --release )

BIN="${SRC_DIR}/target/release/niri"
[ -x "$BIN" ] || die "build finished but ${BIN} is missing"

# --- install ---------------------------------------------------------------
#
# These six files are what make niri a real session rather than just a binary:
#
#   niri                  the compositor
#   niri-session          wrapper gdm actually execs; imports the environment
#                         and starts niri.service under the systemd user manager
#   niri.desktop          THE session picker entry — must be system-wide
#   niri-portals.conf     tells xdg-desktop-portal what to use for XDG_CURRENT_DESKTOP=niri
#   niri.service          the systemd user unit; running under it is what makes
#                         ~/.config/environment.d/95-nix-profile.conf apply, so
#                         niri's `spawn` actions can find nix-installed dms/fuzzel
#   niri-shutdown.target  clean teardown on logout

info "installing into ${PREFIX} and /etc/systemd/user"
sudo install -Dm755 "$BIN"                                "${PREFIX}/bin/niri"
sudo install -Dm755 "${SRC_DIR}/resources/niri-session"   "${PREFIX}/bin/niri-session"
sudo install -Dm644 "${SRC_DIR}/resources/niri.desktop"   "${PREFIX}/share/wayland-sessions/niri.desktop"
sudo install -Dm644 "${SRC_DIR}/resources/niri-portals.conf" \
                                                          "${PREFIX}/share/xdg-desktop-portal/niri-portals.conf"
sudo install -Dm644 "${SRC_DIR}/resources/niri.service"   "/etc/systemd/user/niri.service"
sudo install -Dm644 "${SRC_DIR}/resources/niri-shutdown.target" \
                                                          "/etc/systemd/user/niri-shutdown.target"

# Upstream ships `Exec=niri-session` and relies on gdm's PATH including
# ${PREFIX}/bin. Pinning it to an absolute path removes the most common cause
# of "niri is in the list but the session dies instantly".
sudo sed -i "s|^Exec=niri-session$|Exec=${PREFIX}/bin/niri-session|" \
    "${PREFIX}/share/wayland-sessions/niri.desktop"

# Tolerate running without a systemd user session (e.g. over a bare SSH
# connection) — the units are on disk either way and will be picked up at login.
systemctl --user daemon-reload 2>/dev/null || {
    warn "could not reach the systemd user manager; units are installed and will"
    warn "  be picked up at next login regardless"
}

# --- verify ----------------------------------------------------------------

info "installed: $("${PREFIX}/bin/niri" --version)"

CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/niri/config.kdl"
if [ -f "$CONFIG" ]; then
    info "validating ${CONFIG}"
    if "${PREFIX}/bin/niri" validate -c "$CONFIG"; then
        info "config validates against this niri"
    else
        warn "config did NOT validate — fix this BEFORE logging out, or the"
        warn "  session will fail to start and you'll be debugging from a TTY."
    fi
else
    warn "no config at ${CONFIG} yet — run 'home-manager switch --flake .#rt-dellpromax-24' first,"
    warn "  then re-run this script (or just 'niri validate') to check it parses."
fi

cat <<EOF

Done.

Next steps:
  1. Restart gdm so it re-scans the session directory (the list is not live):
       sudo systemctl restart gdm3
     This kills your current graphical session — save work first. A reboot
     does the same thing.
  2. At the login screen, click the gear / session picker and choose "Niri".
  3. Your existing Ubuntu GNOME session stays in that list, so a broken niri
     entry is never a lockout.

If niri appears but the session dies immediately, check:
     journalctl --user -u niri -b
     journalctl -b /usr/libexec/gdm-x-session /usr/libexec/gdm-wayland-session

Host-specific display/output settings go in ~/.config/niri/local.kdl, which is
hand-edited and deliberately not managed by nix. niri live-reloads it on save.
EOF
