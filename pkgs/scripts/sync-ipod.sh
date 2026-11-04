# shellcheck shell=bash
# sync-ipod -- push a music library onto a mounted iPod with rsync.
#
# --modify-window=1 is the point of the wrapper: FAT timestamps have 2-second
# granularity, so without it every file looks changed on every run. Run with
# --dry-run first to confirm it isn't about to re-copy the whole library.
#
# The --no-perms/--no-owner/--no-group trio is also FAT-driven: the filesystem
# cannot store them, so asking rsync to preserve them guarantees churn.
set -euo pipefail

show_help() {
  cat <<'EOF'
sync-ipod -- rsync a music library onto a mounted iPod

Usage:
  sync-ipod FROM TO
  sync-ipod -f FROM -t TO

Options:
  -h, --help     Show this help message
  -f, --from     The music library location (source)
  -t, --to       The local iPod mount (destination)
  -n, --dry-run  Pass --dry-run to rsync: report, copy nothing

Example:
  sync-ipod user@server:/mnt/share/media/music/ \
            /run/media/rileytuttle/IPOD/iPod_Control/Music/
EOF
}

if [[ $# -eq 0 ]]; then
  show_help
  exit 0
fi

from=""
to=""
dry_run=false
positional=()

while [[ $# -gt 0 ]]; do
  case $1 in
    -h | --help)
      show_help
      exit 0
      ;;
    -f | --from)
      [[ $# -ge 2 ]] || {
        echo "sync-ipod: $1 needs a value" >&2
        exit 1
      }
      from=$2
      shift 2
      ;;
    -t | --to)
      [[ $# -ge 2 ]] || {
        echo "sync-ipod: $1 needs a value" >&2
        exit 1
      }
      to=$2
      shift 2
      ;;
    -n | --dry-run)
      dry_run=true
      shift
      ;;
    -*)
      echo "sync-ipod: unknown option $1" >&2
      show_help >&2
      exit 1
      ;;
    *)
      positional+=("$1")
      shift
      ;;
  esac
done

# Positional args fill in whichever of from/to the flags didn't set.
if [[ -z $from && ${#positional[@]} -ge 1 ]]; then
  from=${positional[0]}
  positional=("${positional[@]:1}")
fi
if [[ -z $to && ${#positional[@]} -ge 1 ]]; then
  to=${positional[0]}
  positional=("${positional[@]:1}")
fi

if [[ ${#positional[@]} -gt 0 ]]; then
  echo "sync-ipod: unexpected extra argument: ${positional[0]}" >&2
  exit 1
fi

if [[ -z $from || -z $to ]]; then
  echo "sync-ipod: need both a source and a destination" >&2
  show_help >&2
  exit 1
fi

rsync_args=(
  -avh
  --no-perms
  --no-owner
  --no-group
  --delete
  --modify-window=1
)
if [[ $dry_run == true ]]; then
  rsync_args+=(--dry-run)
fi

# Quoted, unlike the original: music paths routinely contain spaces.
exec rsync "${rsync_args[@]}" "$from" "$to"
