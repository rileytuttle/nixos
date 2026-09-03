# modules/smart-sleep.nix
#
# Wraps `systemctl hibernate` (or any other sleep verb) so a failure doesn't
# just silently leave the laptop sitting there awake:
#  - every attempt is logged to ~/.local/state/smart-sleep.log and to the
#    journal (`journalctl -t smart-sleep`), so the reason survives even if
#    you never see the notification (e.g. the battery dies before you're
#    back)
#  - on failure, best-effort scan for processes holding a memfd_secret()
#    mapping, since that's what globally disables kernel-level hibernation
#    (this is how we tracked the fw12 hibernate failures down to Bitwarden)
#    -- named in the log/notification instead of just the generic systemd
#    error text
#  - fires a critical, non-expiring desktop notification on failure
#
# Point DMS's sleep/hibernate action at `smart-sleep hibernate` (or
# `smart-sleep suspend-then-hibernate`) instead of calling systemctl
# directly.
{ pkgs, ... }:

let
  smart-sleep = pkgs.writeShellApplication {
    name = "smart-sleep";
    runtimeInputs = with pkgs; [ coreutils gnugrep util-linux libnotify systemd ];
    text = ''
      shopt -s nullglob

      verb="''${1:-hibernate}"
      log_file="''${XDG_STATE_HOME:-$HOME/.local/state}/smart-sleep.log"
      mkdir -p "$(dirname "$log_file")"

      record() {
        printf '%s [%s] %s\n' "$(date --iso-8601=seconds)" "$verb" "$1" >> "$log_file"
        logger -t smart-sleep -- "$1"
      }

      if output=$(systemctl "$verb" 2>&1); then
        record "ok"
        exit 0
      fi
      rc=$?

      culprits=""
      for maps in /proc/[0-9]*/maps; do
        pid="''${maps#/proc/}"
        pid="''${pid%/maps}"
        if grep -q secretmem "$maps" 2>/dev/null; then
          comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo unknown)
          culprits="''${culprits:+$culprits, }$comm (pid $pid)"
        fi
      done

      reason="systemctl $verb failed: ''${output:-no output}"
      if [ -n "$culprits" ]; then
        reason="$reason -- holding secret memory (blocks hibernation kernel-wide): $culprits"
      fi

      record "$reason"
      notify-send -u critical -t 0 "Sleep failed ($verb)" "$reason"

      exit "$rc"
    '';
  };
in {
  environment.systemPackages = [ smart-sleep ];
}
