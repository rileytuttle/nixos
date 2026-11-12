# scripts/xe-engine-util.nix
#
# `nix run .#xe-engine-util` -- live per-engine GPU busy% on the xe driver,
# read straight out of DRM fdinfo. Refreshes until Ctrl-C, like nvtop.
# `--once` for a single sample instead.
#
# This exists because neither tool in the gpu devShell can show you a video
# transcode's real GPU load on this board:
#
#  - nvtop's GPU% column is render + compute ONLY. Its xe backend
#    (src/extract_gpuinfo_intel_xe.c) computes gpu_usage from drm-cycles-rcs
#    plus drm-cycles-ccs, routes drm-cycles-vcs to a separate `decode_usage`
#    field shown under DEC, and never assigns drm-cycles-vecs to any usage
#    field at all. So a QSV transcode reads 0% GPU while pegging the video
#    engine, and the VEBOX time spent in vpp_qsv scaling is invisible
#    whichever column you look at.
#  - intel_gpu_top's engine counters only know the i915 PMU and fail with
#    "Failed to detect engines!" here. See the note in flake.nix.
#
# Measured on fw12 during a 4K->1440p hevc_qsv transcode, this reported
# vcs 99% and vecs 53% while nvtop showed GPU% 0 for the same pid -- which
# is how we established the encode was fully GPU-bound rather than silently
# falling back to libx265. The desktop compositor in the same frame showed
# 21% render and nothing else, which is the GPU% nvtop *does* report.
#
# No root needed: fdinfo for your own processes is readable, and that
# includes processes inside a container running as your uid (the Tdarr node
# runs as puid 1000), because the host sees them in its own /proc.
#
# Engine names are the kernel's: rcs render, ccs compute, vcs video
# (HEVC decode AND encode both land here on Intel), vecs video-enhance
# (scaling/deinterlace), bcs blitter.
{ pkgs }:

pkgs.writeShellApplication {
  name = "xe-engine-util";
  runtimeInputs = with pkgs; [
    coreutils
    gawk
    gnugrep
  ];
  text = ''
    interval=2
    pid=""
    once=false

    while [ "$#" -gt 0 ]; do
      case "$1" in
        -n|--interval)
          shift
          [ "$#" -gt 0 ] || { echo "xe-engine-util: -n needs a value" >&2; exit 2; }
          interval="$1"
          ;;
        -1|--once) once=true ;;
        -h|--help)
          echo "xe-engine-util [-n SECONDS] [--once] [PID]"
          echo
          echo "  Live per-engine GPU utilisation, refreshing until Ctrl-C."
          echo
          echo "  PID            only this process. Default: every process holding"
          echo "                 an xe DRM client that used the GPU in the window."
          echo "  -n SECONDS     refresh interval, also the measurement window"
          echo "                 (default 2). Utilisation is a delta over it, so"
          echo "                 a very short one is noisy."
          echo "  --once, -1     print one sample and exit, for scripting."
          echo
          echo "nvtop's GPU% is render+compute only; VIDEO shows under DEC and"
          echo "V-ENH is not shown at all. That is why this script exists."
          exit 0
          ;;
        -*) echo "xe-engine-util: unknown flag $1" >&2; exit 2 ;;
        *)
          if [ -n "$pid" ]; then
            echo "xe-engine-util: unexpected argument $1" >&2; exit 2
          fi
          pid="$1"
          ;;
      esac
      shift
    done

    if [ -n "$pid" ] && [ ! -d "/proc/$pid" ]; then
      echo "xe-engine-util: no process $pid" >&2; exit 2
    fi

    tmpdir=$(mktemp -d)
    cleanup() {
      rm -rf "$tmpdir"
      # Unhide the cursor and drop below the frame, or the shell prompt comes
      # back on top of the table with no cursor.
      if [ "$once" != true ]; then printf '\033[?25h\n'; fi
    }
    # A bare `trap cleanup INT` would run cleanup and then RESUME the loop,
    # since the handler does not exit. Let the signal handler exit and let
    # the EXIT trap do the cleaning, once.
    trap cleanup EXIT
    trap 'exit 130' INT TERM

    # -s swallows the fdinfo files belonging to other users, and grep exits
    # 1 when nothing matches, which set -e would otherwise treat as fatal.
    # One grep per pid rather than one glob over every fdinfo on the system:
    # that glob can run to tens of thousands of paths and hit ARG_MAX.
    #
    # Re-run every frame, not once at startup: jobs start and finish while
    # this is left up, and a client that vanishes must drop off the table.
    # Glob expansion into the shell's own positional parameters is not bound
    # by ARG_MAX (only exec is), and printf is a builtin, so the huge list
    # reaches xargs without ever being passed to an exec. xargs then chunks
    # it into a handful of greps. Doing this as one grep per pid instead
    # costs ~1000 process spawns per sample, which at a 2s refresh is most
    # of the frame budget.
    find_clients() {
      if [ -n "$pid" ]; then
        set -- "/proc/$pid"/fdinfo/*
      else
        set -- /proc/[0-9]*/fdinfo/*
      fi
      printf '%s\n' "$@" \
        | xargs -r grep -ls '^drm-driver:[[:space:]]*xe' 2>/dev/null || true
    }

    # A process can hold several fds onto the SAME DRM client, so records are
    # keyed by client-id and deduped in the reducer -- otherwise one client's
    # cycles get counted once per fd.
    # One awk over every client file rather than one awk per file: the pid
    # comes from FILENAME, and gawk's ENDFILE flushes each file's totals.
    sample() {
      : > "$1"
      find_clients > "$tmpdir/clients"
      [ -s "$tmpdir/clients" ] || return 0
      # The $1/$2 below are awk fields, not shell parameters. shellcheck
      # cannot tell, because xargs in front of awk hides that this quoted
      # string is awk source.
      # shellcheck disable=SC2016
      xargs -r -a "$tmpdir/clients" awk '
        FNR == 1 {
          split(FILENAME, parts, "/"); pid = parts[3]
          delete cyc; delete tot; cid = ""
        }
        /^drm-client-id:/    { cid = $2 }
        /^drm-pdev:/         { pdev = $2 }
        /^drm-cycles-/       { e = $1; sub(/^drm-cycles-/, "", e);       sub(/:$/, "", e); cyc[e] = $2 }
        /^drm-total-cycles-/ { e = $1; sub(/^drm-total-cycles-/, "", e); sub(/:$/, "", e); tot[e] = $2 }
        ENDFILE {
          for (e in cyc) printf "%s|%s|%s|%s|%s|%s\n", pid, cid, e, cyc[e], tot[e] + 0, pdev
        }
      ' >> "$1" 2>/dev/null || true
    }

    render() {
      awk -F'|' -v interval="$interval" -v single="''${pid:+1}" -v live="$2" '
        NR == FNR { c0[$1 "|" $2 "|" $3] = $4; t0[$1 "|" $2 "|" $3] = $5; next }
        {
          card = $6
          k = $1 "|" $2 "|" $3
          if (!(k in c0)) next                 # client appeared mid-window
          dt = $5 - t0[k]
          if (dt <= 0) next
          # Sum cycles across a pid every client, but total-cycles is a shared
          # reference clock, so it is assigned rather than accumulated.
          cyc[$1 "|" $3] += $4 - c0[k]
          tot[$1 "|" $3]  = dt
          seen[$1] = 1
        }
        END {
          # Erase to end of line on every row, so a frame that is narrower or
          # shorter than the last one does not leave debris behind.
          K = live ? sprintf("%c[K", 27) : ""
          n = split("rcs ccs vcs vecs bcs", order, " ")
          split("RENDER COMPUTE VIDEO V-ENH BLIT", label, " ")

          stamp = ""
          if (live) { "date +%H:%M:%S" | getline stamp; close("date +%H:%M:%S") }
          printf "xe engine utilisation  %ss window%s%s%s\n%s\n",
                 interval, (card ? "  " card : ""),
                 (stamp ? "   " stamp : ""), K, K

          printf "%9s %-18s", "PID", "COMMAND"
          for (i = 1; i <= n; i++) printf "%8s", label[i]
          printf "%s\n", K

          # Busiest first, and deterministically: a hash walk would reshuffle
          # the rows on every frame.
          for (p in seen) {
            score[p] = 0
            for (i = 1; i <= n; i++) {
              k = p "|" order[i]
              v = (k in tot && tot[k] > 0) ? 100 * cyc[k] / tot[k] : 0
              pct[p, i] = v
              if (v > score[p]) score[p] = v
              sum[i] += v
            }
          }

          PROCINFO["sorted_in"] = "@val_num_desc"
          rows = 0
          for (p in score) {
            if (score[p] < 0.05 && !single) continue
            cmd = "unknown"
            if ((getline line < ("/proc/" p "/comm")) > 0) cmd = line
            close("/proc/" p "/comm")
            printf "%9s %-18s", p, substr(cmd, 1, 18)
            for (i = 1; i <= n; i++) printf "%7.1f%%", pct[p, i]
            printf "%s\n", K
            rows++
          }

          if (rows == 0) printf "  (no engine activity in this window)%s\n", K
          else if (rows > 1) {
            printf "%9s %-18s", "", "ALL"
            for (i = 1; i <= n; i++) printf "%7.1f%%", sum[i]
            printf "%s\n", K
          }

          printf "%s\n", K
          printf "nvtop GPU%% = RENDER + COMPUTE only. VIDEO is its DEC column;%s\n", K
          printf "V-ENH feeds no nvtop field at all, so vpp_qsv scaling is%s\n", K
          printf "invisible there. A QSV transcode is VIDEO + V-ENH, hence 0%% GPU.%s\n", K
          if (live) printf "Ctrl-C to quit.%s\n", K
        }
      ' "$1" "$3"
    }

    # No xe clients at all means the wrong driver (or the wrong pid), not an
    # idle GPU -- the compositor always holds one. Worth saying so rather
    # than leaving an empty table up forever.
    if [ -z "$(find_clients)" ]; then
      echo "xe-engine-util: no xe DRM clients found''${pid:+ for pid $pid}." >&2
      echo "  Is this machine actually on the xe driver? Check:" >&2
      echo "    readlink -f /sys/class/drm/card0/device/driver" >&2
      exit 1
    fi

    if [ "$once" = true ]; then
      sample "$tmpdir/t0"
      sleep "$interval"
      sample "$tmpdir/t1"
      printf '\n'
      render "$tmpdir/t0" "" "$tmpdir/t1"
      exit 0
    fi

    # Live mode. The previous frame's sample is this frame's baseline, so
    # there is no dead time between measurement windows.
    printf '\033[?25l\033[2J'
    sample "$tmpdir/prev"
    while true; do
      sleep "$interval"
      sample "$tmpdir/cur"
      printf '\033[H'
      render "$tmpdir/prev" 1 "$tmpdir/cur"
      printf '\033[J'
      mv -f "$tmpdir/cur" "$tmpdir/prev"
    done
  '';
}
