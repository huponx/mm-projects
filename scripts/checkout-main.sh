#!/usr/bin/env bash
# Checks out the main branch in every sub-folder of DIR (default: the workspace root) that is a git repository.
# First it looks at all of them: when one has changes that are not committed (or untracked files) it lists them
# and stops, before any checkout, so nothing is half done.
# With a third argument "pull" each repository also runs `git pull origin <branch>` after the checkout (a plain pull:
# it may merge; a conflict or any other failure stops the run).
set -euo pipefail

dir="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
branch="${2:-main}"
pull="${3:-}"

repos=()
for g in "$dir"/*/.git; do
  [ -e "$g" ] && repos+=("$(dirname "$g")")
done
if [ ${#repos[@]} -eq 0 ]; then
  echo "no git repository in the sub-folders of $dir"
  exit 0
fi

dirty=0
for r in "${repos[@]}"; do
  if [ -n "$(git -C "$r" status --porcelain)" ]; then
    echo "not committed in $(basename "$r") ($(git -C "$r" branch --show-current)):" >&2
    git -C "$r" status --short | sed 's/^/    /' >&2
    dirty=1
  fi
done
if [ "$dirty" -ne 0 ]; then
  echo "stopped: commit or stash these changes first, nothing was checked out" >&2
  exit 1
fi

for r in "${repos[@]}"; do
  name="$(basename "$r")"
  if [ "$(git -C "$r" branch --show-current)" = "$branch" ]; then
    echo "$name: already on $branch"
  elif git -C "$r" checkout -q "$branch"; then
    echo "$name: $branch"
  else
    echo "$name: cannot check out $branch" >&2
    exit 1
  fi
  if [ "$pull" = "pull" ]; then
    if git -C "$r" pull -q origin "$branch"; then
      echo "$name: pulled origin/$branch"
    else
      echo "$name: cannot pull origin/$branch" >&2
      exit 1
    fi
  fi
done
