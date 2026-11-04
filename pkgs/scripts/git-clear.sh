# shellcheck shell=bash
# `git clear` -- throw away every tracked change on the current branch.
#
# Packaged as git-clear by pkgs/scripts.nix, so git finds it on PATH and
# `git clear` works as a subcommand.
#
# Stashes and immediately drops the stash. The guard around that matters: a
# bare `git stash && git stash drop` (what this script used to do) silently
# destroys an UNRELATED older stash when the tree is already clean, because
# `git stash` succeeds with "No local changes to save" without pushing
# anything and `drop` then removes whatever was on top. So compare refs/stash
# before and after, and only drop when this run actually pushed something.
set -euo pipefail

if ! branch=$(git symbolic-ref --short -q HEAD); then
  echo "git-clear: not on a branch (detached HEAD?)" >&2
  exit 1
fi

before=$(git rev-parse -q --verify refs/stash || true)
git stash push
after=$(git rev-parse -q --verify refs/stash || true)

if [[ $before == "$after" ]]; then
  echo "git-clear: nothing was stashed; leaving existing stashes untouched"
  exit 0
fi

echo "git-clear: clearing out diff on $branch"
git stash drop
