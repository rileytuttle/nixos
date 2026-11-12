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
#    notification saying so. Bitwarden is the only thing on this system
#    known to hold secret memory, so it's found by name and simply closed
#    -- no scanning for secret-memory holders in general. That scan used
#    to be here and was worse than useless: Electron marks itself
#    non-dumpable, which puts /proc/<pid>/maps out of reach of the very
#    user running the app, so unprivileged it never found Bitwarden and
#    silently skipped closing it. If some other process ever starts
#    blocking hibernation, the log says so and names the root command that
#    will identify it.
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
#  - fires a desktop notification whenever the outcome wasn't a plain,
#    exactly-as-requested success: critical/non-expiring for a total
#    failure, normal for a fallback -- so it's there when you get back even
#    from a suspend that quietly downgraded from suspend-then-hibernate.
#    When run as root, it's sent to every logged-in user's session bus.
#
# Separately, and independent of which verb was used, the s0ix-residency
# unit at the bottom of this file logs after every resume how much of the
# time asleep the hardware really spent in S0ix. This board has no S3, so
# an s2idle that never reached S0ix resumes perfectly and only shows up as
# a mysteriously flat battery -- the residency counter is the only tell.
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
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gnugrep
      gnused
      util-linux
      libnotify
      systemd
    ];
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

      # The kernel's own verdict: "disk" in /sys/power/state.
      hibernate_available() {
        grep -qw disk /sys/power/state 2>/dev/null
      }

      # Why the kernel isn't offering hibernation, for the log. Bitwarden
      # has already been closed by the time this runs, so anything left is
      # something new. The two cheap kernel-level causes are worth naming;
      # for a surprise third process holding memfd_secret there's no point
      # carrying a scanner that can't see non-dumpable processes anyway
      # (see close_bitwarden) -- the one-off root command is better.
      hibernate_blocker() {
        reasons=()
        if grep -qw nohibernate /proc/cmdline 2>/dev/null; then
          reasons+=("kernel booted with nohibernate")
        fi
        if grep -qE '\[(integrity|confidentiality)\]' /sys/kernel/security/lockdown 2>/dev/null; then
          reasons+=("kernel lockdown is active ($(cat /sys/kernel/security/lockdown))")
        fi
        if [ "''${#reasons[@]}" -eq 0 ]; then
          reasons+=("cause unknown, and Bitwarden was not it -- if something else is holding memfd_secret, 'sudo grep -ls secretmem /proc/[0-9]*/maps' will name it")
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

      # Never signal ourselves or whatever launched us. Matching on cmdline
      # means a shell invoked as e.g. `smart-sleep hibernate # bitwarden`
      # would otherwise look like Bitwarden and get killed along with it.
      is_self_or_ancestor() {
        local target="$1" pid=$$
        while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
          [ "$pid" = "$target" ] && return 0
          pid=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$pid/status" 2>/dev/null)
        done
        return 1
      }

      # Every Bitwarden process, by its own cmdline. Has to go by cmdline:
      # Bitwarden is Electron, Electron calls prctl(PR_SET_DUMPABLE, 0) on
      # itself, and that hands /proc/<pid>/{maps,fd,exe} to root:root --
      # unreadable even by the user running the app. /proc/<pid>/cmdline
      # stays readable, so it's the only handle we have when smart-sleep
      # runs as the desktop user (DMS power menu, DMS idle timeout).
      #
      # Deliberately matches each process's *own* cmdline and does not walk
      # up the parent chain: an ancestor walk also matches anything merely
      # launched from a shell whose command line happens to say "bitwarden".
      bitwarden_pids() {
        local dir pid
        for dir in /proc/[0-9]*; do
          pid="''${dir##*/}"
          is_self_or_ancestor "$pid" && continue
          if grep -qi bitwarden "$dir/cmdline" 2>/dev/null; then
            printf '%s\n' "$pid"
          fi
        done
      }

      # Just the Electron main process(es) -- the ones to SIGTERM, so the
      # app shuts down cleanly instead of losing a renderer first. Every
      # Chromium child process carries --type=; the main process doesn't.
      # (Parentage is no use for this: Chromium's children hang off zygote
      # processes, so walking PPid never converges on the main process.)
      bitwarden_main_pids() {
        local dir
        for dir in /proc/[0-9]*; do
          is_self_or_ancestor "''${dir##*/}" && continue
          grep -qi bitwarden "$dir/cmdline" 2>/dev/null || continue
          grep -q -e '--type=' "$dir/cmdline" 2>/dev/null && continue
          printf '%s\n' "''${dir##*/}"
        done
      }

      close_bitwarden() {
        # Already offering hibernation means nothing is holding secret
        # memory, so leave a locked Bitwarden alone.
        hibernate_available && return 0

        mapfile -t mains < <(bitwarden_main_pids)
        [ "''${#mains[@]}" -gt 0 ] || return 0

        record "closing Bitwarden so hibernate is possible: $(describe "''${mains[@]}")"
        kill -TERM "''${mains[@]}" 2>/dev/null || true

        # Wait on the kernel's own verdict, not on the processes
        # disappearing: /sys/power/state is readable by anyone and is the
        # thing we actually need changed.
        for _ in $(seq 20); do
          hibernate_available && break
          sleep 0.5
        done

        if ! hibernate_available; then
          mapfile -t pids < <(bitwarden_pids)
          if [ "''${#pids[@]}" -gt 0 ]; then
            record "Bitwarden ignored SIGTERM, killing: $(describe "''${pids[@]}")"
            kill -KILL "''${pids[@]}" 2>/dev/null || true
            for _ in $(seq 10); do
              hibernate_available && break
              sleep 0.5
            done
          fi
        fi

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
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      systemd
      smart-sleep
    ];
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
in
{
  environment.systemPackages = [ smart-sleep ];

  # Lid close goes through smart-sleep (see top of file), not logind.
  services.acpid = {
    enable = true;
    lidEventCommands = ''${smart-sleep-lid}/bin/smart-sleep-lid "$@"'';
  };
  services.logind.settings.Login.HandleLidSwitch = "ignore";

  # Record, on each resume, how much of the time asleep the platform really
  # spent in hardware sleep.
  #
  # This matters because there is no S3 on this mainboard -- suspend is
  # always s2idle, and s2idle that never reaches S0ix is invisible from
  # userspace: the machine suspends, resumes fine, and just happens to have
  # drained the battery as if it had been awake the whole time. The only
  # way to tell is the residency counter. intel_pmc_core feeds the kernel's
  # pm_report_hw_sleep_time(), which surfaces as
  # /sys/power/suspend_stats/last_hw_sleep (microseconds, from the PMC's
  # SLP_S0 counter) and reads 0 when the deepest state was never entered.
  #
  # Shaped like nixpkgs' own sleep-actions unit
  # (nixos/modules/config/power-management.nix): wanted by and ordered
  # before sleep.target, so `script` runs on the way down and `preStop`
  # runs on the way back up.
  systemd.services.s0ix-residency = {
    description = "Record hardware sleep (S0ix) residency across suspend";
    wantedBy = [ "sleep.target" ];
    before = [ "sleep.target" ];
    unitConfig.StopWhenUnneeded = true;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [
      coreutils
      util-linux
    ];

    # Wall clock and CLOCK_BOOTTIME (/proc/uptime), so the two can be
    # differenced on resume -- see preStop.
    script = ''
      { date +%s; cut -d' ' -f1 /proc/uptime; } > /run/s0ix-residency.stamp
    '';

    preStop = ''
      log() {
        printf '%s [s0ix] %s\n' "$(date --iso-8601=seconds)" "$1" \
          >> /var/log/smart-sleep.log
        logger -t smart-sleep -- "$1"
      }

      stamp=/run/s0ix-residency.stamp
      [ -r "$stamp" ] || exit 0
      # NixOS runs this under `set -e`, and a short stamp makes the second
      # read fail at EOF -- which would abort before the guard below could
      # say anything. Let both reads fail and judge the values instead.
      start_wall=""
      start_boot=""
      { read -r start_wall || true; read -r start_boot || true; } < "$stamp"
      rm -f "$stamp"

      # A stamp truncated by a crash mid-write (or carried oddly across a
      # hibernation image) would otherwise sail through the arithmetic
      # below and log a line full of blanks. Bail loudly instead. Both
      # fields have to be checked on their own -- testing them concatenated
      # lets a present-but-alone first field pass.
      is_num() {
        case "''${1:-}" in
          "" | *[!0-9.]*) return 1 ;;
          *) return 0 ;;
        esac
      }
      if ! is_num "$start_wall" || ! is_num "$start_boot"; then
        log "unusable sleep stamp (wall='$start_wall' boot='$start_boot'); skipping residency report"
        exit 0
      fi

      now_wall=$(date +%s)
      now_boot=$(cut -d' ' -f1 /proc/uptime)

      wall=$((now_wall - start_wall))
      # /proc/uptime is fractional; integer seconds are plenty here.
      boot=$(( ''${now_boot%.*} - ''${start_boot%.*} ))

      # Wall clock advances while powered off, CLOCK_BOOTTIME may not, so a
      # gap between the two means a suspend-then-hibernate actually went
      # all the way to disk. The residency counter only covers the s2idle
      # phase before that, so judge it against `boot`, not `wall`.
      off=$((wall - boot))
      if [ "$off" -gt 10 ]; then
        asleep="$boot"
        suffix=" (plus ''${off}s powered off, so this covers the s2idle phase only)"
      else
        asleep="$wall"
        suffix=""
      fi

      hw=$(cat /sys/power/suspend_stats/last_hw_sleep 2>/dev/null) || hw=""
      if [ -z "$hw" ]; then
        log "asleep ''${asleep}s; no hardware sleep counter on this platform$suffix"
        exit 0
      fi

      # Under a minute, suspend and resume themselves dominate and a low
      # ratio means nothing, so report the raw numbers and don't judge.
      if [ "$asleep" -lt 60 ]; then
        log "asleep ''${asleep}s, last_hw_sleep=''${hw}us -- too short to judge$suffix"
        exit 0
      fi

      # hw/(asleep * 1e6) * 100, with the divisions ordered to stay in
      # integer arithmetic. The raw microseconds are logged alongside so the
      # unit can be sanity-checked against a known-length suspend.
      pct=$((hw / 10000 / asleep))
      if [ "$hw" -eq 0 ]; then
        log "asleep ''${asleep}s but NEVER reached hardware sleep (last_hw_sleep=0)$suffix -- chase it with /sys/kernel/debug/pmc_core/substate_residencies and ltr_show"
      elif [ "$pct" -lt 80 ]; then
        log "asleep ''${asleep}s, only ''${pct}% in hardware sleep (last_hw_sleep=''${hw}us)$suffix -- chase it with /sys/kernel/debug/pmc_core/substate_residencies and ltr_show"
      else
        log "asleep ''${asleep}s, ''${pct}% in hardware sleep (last_hw_sleep=''${hw}us)$suffix"
      fi
    '';
  };
}
