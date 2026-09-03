# modules/smart-sleep.nix
#
# Wraps `systemctl <verb>` (hibernate, suspend, suspend-then-hibernate, ...)
# so a failure doesn't just silently leave the laptop sitting there awake:
#  - suspend-then-hibernate (and hybrid-sleep) refuse to even start if
#    hibernate isn't currently available -- systemd gates the whole
#    composite operation on hibernate support up front, it doesn't just
#    suspend and skip the later hibernate step. So on failure for those two
#    verbs, we fall back to a plain `systemctl suspend` ourselves, so the
#    laptop still actually sleeps.
#  - every attempt (success, fallback, or total failure) is logged to
#    ~/.local/state/smart-sleep.log and to the journal
#    (`journalctl -t smart-sleep`), so the reason survives even if you
#    never see a notification (e.g. the battery dies before you're back)
#  - on a fallback or total failure, best-effort scan for processes holding
#    a memfd_secret() mapping, since that's what globally disables
#    kernel-level hibernation (this is how we tracked the fw12 hibernate
#    failures down to Bitwarden) -- named in the log/notification instead
#    of just the generic systemd error text
#  - fires a desktop notification on wake whenever the outcome wasn't a
#    plain, exactly-as-requested success: critical/non-expiring for a
#    total failure, normal for a fallback -- so it's there when you get
#    back even from a suspend that quietly downgraded from
#    suspend-then-hibernate
#
# Point DMS's sleep/hibernate action at `smart-sleep hibernate`,
# `smart-sleep suspend`, or `smart-sleep suspend-then-hibernate` instead of
# calling systemctl directly.
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

      secretmem_culprits() {
        found=""
        for maps in /proc/[0-9]*/maps; do
          pid="''${maps#/proc/}"
          pid="''${pid%/maps}"
          if grep -q secretmem "$maps" 2>/dev/null; then
            comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo unknown)
            found="''${found:+$found, }$comm (pid $pid)"
          fi
        done
        printf '%s' "$found"
      }

      if output=$(systemctl "$verb" 2>&1); then
        record "ok"
        exit 0
      fi
      rc=$?

      # suspend-then-hibernate/hybrid-sleep won't even attempt the suspend
      # half if hibernate support is missing -- fall back to plain suspend
      # so the laptop still sleeps.
      fell_back=false
      fallback_output=""
      case "$verb" in
        suspend-then-hibernate | hybrid-sleep)
          if fallback_output=$(systemctl suspend 2>&1); then
            fell_back=true
          fi
          ;;
      esac

      note=""
      culprits="$(secretmem_culprits)"
      if [ -n "$culprits" ]; then
        note=" -- holding secret memory (blocks hibernation kernel-wide): $culprits"
      fi

      if [ "$fell_back" = true ]; then
        reason="systemctl $verb failed (''${output:-no output}); fell back to plain suspend instead$note"
        record "$reason"
        notify-send -u normal -t 0 "Slept via fallback ($verb -> suspend)" "$reason"
        exit 0
      fi

      reason="systemctl $verb failed: ''${output:-no output}$note"
      if [ -n "$fallback_output" ]; then
        reason="$reason | fallback suspend also failed: $fallback_output"
      fi
      record "$reason"
      notify-send -u critical -t 0 "Sleep failed ($verb)" "$reason"

      exit "$rc"
    '';
  };
in {
  environment.systemPackages = [ smart-sleep ];
}
