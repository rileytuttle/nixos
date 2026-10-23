# modules/smart-sleep.nix
#
# Wraps `systemctl <verb>` (hibernate, suspend, suspend-then-hibernate, ...)
# so a failure doesn't just silently leave the laptop sitting there awake:
#  - before any verb that writes RAM to disk (hibernate,
#    suspend-then-hibernate, hybrid-sleep), close Bitwarden. Bitwarden
#    keeps its keys in a memfd_secret() mapping, and while any process
#    holds one the kernel refuses to hibernate at all (so secrets never
#    land in the unencrypted swap image). There's no CLI to lock the
#    running desktop app, and locking wouldn't release the mapping anyway,
#    so it gets SIGTERM (then SIGKILL if it hangs around) and a
#    notification saying so.
#  - suspend-then-hibernate (and hybrid-sleep) refuse to even start if
#    hibernate isn't currently available -- systemd gates the whole
#    composite operation on hibernate support up front, it doesn't just
#    suspend and skip the later hibernate step. So on failure for those two
#    verbs, we fall back to a plain `systemctl suspend` ourselves, so the
#    laptop still actually sleeps.
#  - every attempt (success, fallback, or total failure) is logged to
#    ~/.local/state/smart-sleep.log (/var/log/smart-sleep.log when run as
#    root, e.g. from the lid handler below) and to the journal
#    (`journalctl -t smart-sleep`), so the reason survives even if you
#    never see a notification (e.g. the battery dies before you're back)
#  - on a fallback or total failure, best-effort scan for anything else
#    still holding a memfd_secret() mapping, named in the log/notification
#    instead of just the generic systemd error text
#  - fires a desktop notification whenever the outcome wasn't a plain,
#    exactly-as-requested success: critical/non-expiring for a total
#    failure, normal for a fallback -- so it's there when you get back even
#    from a suspend that quietly downgraded from suspend-then-hibernate.
#    When run as root, it's sent to every logged-in user's session bus.
#
# Entry points:
#  - lid close: acpid runs smart-sleep-lid (below) as root, and logind's
#    own lid handling is switched off. logind decides up front whether
#    suspend-then-hibernate is possible, before any sleep hook could close
#    Bitwarden, so it has to be bypassed rather than hooked.
#  - DMS power menu / idle suspend: hosts/fw12.nix points DMS's custom
#    suspend/hibernate actions at `smart-sleep suspend-then-hibernate` /
#    `smart-sleep hibernate`.
{ pkgs, ... }:

let
  smart-sleep = pkgs.writeShellApplication {
    name = "smart-sleep";
    runtimeInputs = with pkgs; [ coreutils findutils gnugrep gnused util-linux libnotify systemd ];
    text = ''
      shopt -s nullglob

      verb="''${1:-hibernate}"
      if [ "$(id -u)" -eq 0 ]; then
        log_file=/var/log/smart-sleep.log
      else
        log_file="''${XDG_STATE_HOME:-''${HOME:-/tmp}/.local/state}/smart-sleep.log"
      fi
      mkdir -p "$(dirname "$log_file")"

      record() {
        printf '%s [%s] %s\n' "$(date --iso-8601=seconds)" "$verb" "$1" >> "$log_file"
        logger -t smart-sleep -- "$1"
      }

      # notify <urgency> <expire-ms> <summary> <body>
      notify() {
        if [ "$(id -u)" -ne 0 ]; then
          notify-send -u "$1" -t "$2" "$3" "$4" || true
          return
        fi
        for dir in /run/user/[0-9]*; do
          uid="''${dir##*/}"
          [ "$uid" -ge 1000 ] && [ -S "$dir/bus" ] || continue
          user=$(id -nu "$uid" 2>/dev/null) || continue
          runuser -u "$user" -- env DBUS_SESSION_BUS_ADDRESS="unix:path=$dir/bus" \
            notify-send -u "$1" -t "$2" "$3" "$4" || true
        done
      }

      # PIDs (one per line) holding a memfd_secret() file. The kernel blocks
      # hibernation while any such file is open, mapped or not -- so check
      # open fds as well as mappings (a child can inherit the fd without
      # ever mapping it).
      secretmem_pids() {
        {
          grep -ls secretmem /proc/[0-9]*/maps || true
          find /proc/[0-9]*/fd -maxdepth 1 -lname '*secretmem*' 2>/dev/null || true
        } | cut -d/ -f3 | sort -un
      }

      # The kernel's own verdict: "disk" in /sys/power/state.
      hibernate_available() {
        grep -qw disk /sys/power/state 2>/dev/null
      }

      # Best guess at why the kernel isn't offering hibernation.
      hibernate_blocker() {
        reasons=()
        if grep -qw nohibernate /proc/cmdline 2>/dev/null; then
          reasons+=("kernel booted with nohibernate")
        fi
        if grep -qE '\[(integrity|confidentiality)\]' /sys/kernel/security/lockdown 2>/dev/null; then
          reasons+=("kernel lockdown is active ($(cat /sys/kernel/security/lockdown))")
        fi
        mapfile -t holders < <(secretmem_pids)
        if [ "''${#holders[@]}" -gt 0 ]; then
          reasons+=("holding secret memory: $(describe "''${holders[@]}")")
        fi
        if [ "''${#reasons[@]}" -eq 0 ]; then
          reasons+=("no visible cause; secret memory may be held by another user's process (run as root to see all)")
        fi
        local IFS=';'
        printf 'hibernate unavailable (/sys/power/state: %s): %s' \
          "$(cat /sys/power/state 2>/dev/null)" "''${reasons[*]}"
      }

      describe() {
        found=""
        for pid in "$@"; do
          comm=$(cat "/proc/$pid/comm" 2>/dev/null || echo unknown)
          found="''${found:+$found, }$comm (pid $pid)"
        done
        printf '%s' "$found"
      }

      # Bitwarden itself, or a helper it spawned (whose own cmdline may not
      # mention Bitwarden at all).
      is_bitwarden() {
        local pid="$1"
        while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
          grep -qi bitwarden "/proc/$pid/cmdline" 2>/dev/null && return 0
          pid=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$pid/status" 2>/dev/null)
        done
        return 1
      }

      # Secret-memory holders that belong to Bitwarden.
      bitwarden_holders() {
        for pid in $(secretmem_pids); do
          if is_bitwarden "$pid"; then
            printf '%s\n' "$pid"
          fi
        done
      }

      # The holder may be an Electron child; signal the top-most ancestor
      # running the same binary (the Electron main process) instead, so the
      # whole app shuts down cleanly. Stops before any launcher shell.
      bitwarden_root() {
        pid="$1"
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null || true)
        while parent=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$pid/status" 2>/dev/null) \
          && [ -n "$parent" ] && [ "$parent" -gt 1 ] \
          && [ -n "$exe" ] && [ "$(readlink "/proc/$parent/exe" 2>/dev/null)" = "$exe" ]; do
          pid="$parent"
        done
        printf '%s' "$pid"
      }

      close_bitwarden() {
        mapfile -t holders < <(bitwarden_holders)
        [ "''${#holders[@]}" -gt 0 ] || return 0

        roots=()
        for pid in "''${holders[@]}"; do
          roots+=("$(bitwarden_root "$pid")")
        done
        record "closing Bitwarden so hibernate is possible: $(describe "''${roots[@]}")"
        kill -TERM "''${roots[@]}" 2>/dev/null || true

        for _ in $(seq 20); do
          [ -z "$(bitwarden_holders)" ] && break
          sleep 0.5
        done
        mapfile -t holders < <(bitwarden_holders)
        if [ "''${#holders[@]}" -gt 0 ]; then
          record "Bitwarden ignored SIGTERM, killing: $(describe "''${holders[@]}")"
          kill -KILL "''${holders[@]}" 2>/dev/null || true
          sleep 1
        fi

        # The kernel lifts the block once the last secretmem file is
        # released; give that a moment to show up in /sys/power/state.
        for _ in $(seq 10); do
          hibernate_available && break
          sleep 0.5
        done

        notify normal 0 "Closed Bitwarden before sleeping" \
          "Bitwarden's secret memory blocks hibernation, so it was closed. Reopen it to unlock again."
      }

      blocker=""
      case "$verb" in
        hibernate | suspend-then-hibernate | hybrid-sleep)
          close_bitwarden
          if ! hibernate_available; then
            blocker=$(hibernate_blocker)
            record "$blocker"
          fi
          ;;
      esac

      output=$(systemctl "$verb" 2>&1) && rc=0 || rc=$?
      if [ "$rc" -eq 0 ]; then
        record "ok"
        exit 0
      fi

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
      if [ -n "$blocker" ]; then
        note=" -- $blocker"
      fi

      if [ "$fell_back" = true ]; then
        reason="systemctl $verb failed (''${output:-no output}); fell back to plain suspend instead$note"
        record "$reason"
        notify normal 0 "Slept via fallback ($verb -> suspend)" "$reason"
        exit 0
      fi

      reason="systemctl $verb failed: ''${output:-no output}$note"
      if [ -n "$fallback_output" ]; then
        reason="$reason | fallback suspend also failed: $fallback_output"
      fi
      record "$reason"
      notify critical 0 "Sleep failed ($verb)" "$reason"

      exit "$rc"
    '';
  };

  # Run by acpid (as root) on every button/lid event, with the event
  # string (e.g. "button/lid LID close") as arguments.
  smart-sleep-lid = pkgs.writeShellApplication {
    name = "smart-sleep-lid";
    runtimeInputs = with pkgs; [ coreutils gnugrep systemd smart-sleep ];
    text = ''
      shopt -s nullglob

      case "$*" in
        *close*) ;;
        *) exit 0 ;;
      esac

      # A desktop that handles the lid itself (Plasma's powerdevil, GNOME)
      # says so with a handle-lid-switch inhibitor -- the same signal
      # logind would have respected. Stay out of its way.
      inhibitors=$(systemd-inhibit --list --no-pager --no-legend 2>/dev/null || true)
      if grep -q 'handle-lid-switch.*block' <<< "$inhibitors"; then
        exit 0
      fi

      # Docked (external display connected): leave it awake, matching
      # logind's default HandleLidSwitchDocked=ignore.
      for status in /sys/class/drm/card*-*/status; do
        connector="''${status%/status}"
        case "''${connector##*/}" in *eDP*) continue ;; esac
        if [ "$(cat "$status")" = connected ]; then
          exit 0
        fi
      done

      exec smart-sleep suspend-then-hibernate
    '';
  };
in {
  environment.systemPackages = [ smart-sleep ];

  # Lid close goes through smart-sleep (see top of file), not logind.
  services.acpid = {
    enable = true;
    lidEventCommands = ''${smart-sleep-lid}/bin/smart-sleep-lid "$@"'';
  };
  services.logind.settings.Login.HandleLidSwitch = "ignore";
}
