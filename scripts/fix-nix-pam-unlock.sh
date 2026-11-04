#!/usr/bin/env bash
#
# Make nix-built PAM clients able to check your password on a non-NixOS
# host (rt-dellpromax-24). Without this, the DMS lock screen (and nix's
# swaylock) accept your password and then silently refuse to unlock.
#
# Why: pam_unix needs the setgid `unix_chkpwd` helper to read /etc/shadow.
# The nix store can't hold setgid binaries, so nixpkgs' linux-pam is patched
# to call /run/wrappers/bin/unix_chkpwd — NixOS's security-wrapper path,
# which doesn't exist on Ubuntu. Quickshell (DMS) links that linux-pam, so
# every unlock attempt fails.
#
# Fix: a systemd-tmpfiles rule that symlinks that path to Ubuntu's own
# setgid helper. /run is a tmpfs, so tmpfiles recreates it on every boot.
#
# Second problem: nix's linux-pam doesn't understand Debian's `@include`
# directive, so every Ubuntu service in /etc/pam.d (login, other, ...)
# parses to an empty auth stack under it. DMS prefers /etc/pam.d/dankshell
# when it exists, so give it a self-contained one that both nix's and
# Ubuntu's libpam can read. Module names are relative on purpose: each
# libpam resolves them against its own module dir.
#
# Safe to re-run.
#
set -euo pipefail

TARGET="/usr/sbin/unix_chkpwd"
RULE_FILE="/etc/tmpfiles.d/nix-unix-chkpwd.conf"
PAM_FILE="/etc/pam.d/dankshell"

[ -x "$TARGET" ] || { echo "error: $TARGET not found (apt install libpam-modules-bin)" >&2; exit 1; }

sudo tee "$RULE_FILE" >/dev/null <<EOF
# Written by scripts/fix-nix-pam-unlock.sh. Lets nix's pam_unix find the
# setgid helper at the NixOS path it was patched to use.
d  /run/wrappers      0755 root root -
d  /run/wrappers/bin  0755 root root -
L+ /run/wrappers/bin/unix_chkpwd - - - - $TARGET
EOF

sudo systemd-tmpfiles --create "$RULE_FILE"
ls -l /run/wrappers/bin/unix_chkpwd

sudo tee "$PAM_FILE" >/dev/null <<'EOF'
#%PAM-1.0
# Written by scripts/fix-nix-pam-unlock.sh for the DMS lock screen. No
# @include: nix's linux-pam can't parse it.
auth     required  pam_unix.so
account  required  pam_unix.so
password required  pam_deny.so
session  required  pam_permit.so
EOF
echo "wrote $PAM_FILE"

cat <<'EOF'

Test with nix's libpam (same one DMS uses) before locking:
  nix shell nixpkgs#pamtester -c pamtester dankshell "$USER" authenticate
Then restart DMS so it picks up the new service:
  pkill -f 'dms run'; setsid dms run >/dev/null 2>&1 &
EOF
