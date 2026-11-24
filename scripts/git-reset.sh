#!/usr/bin/env bash
# Throws away every change that is not committed in the sub-folders of DIR that are git repositories:
# `git reset --hard` (changes of tracked files, staged or not) and `git clean -fd` (new files and folders that are not
# committed; files that .gitignore ignores are kept). The branch and the commits stay as they are.
# It shows what will be lost and asks first; only the answer "yes" starts it (no terminal: it does nothing).
set -euo pipefail

dir="${1:-$(cd "$(dirname "$0")/.." && pwd)}"

repos=()
for g in "$dir"/*/.git; do
  [ -e "$g" ] && repos+=("$(dirname "$g")")
done

todo=()
for r in "${repos[@]+"${repos[@]}"}"; do
  if [ -n "$(git -C "$r" status --porcelain)" ]; then
    todo+=("$r")
  fi
done

if [ ${#todo[@]} -eq 0 ]; then
  echo "nothing to reset: no sub-folder of $dir has changes that are not committed"
  exit 0
fi

echo "WARNING: this deletes work that is not committed, and it cannot be undone:"
echo
for r in "${todo[@]}"; do
  echo "  $(basename "$r") ($(git -C "$r" branch --show-current))"
  git -C "$r" status --short | sed 's/^/      /'
done
echo
echo "  M/D/A/R = changes of tracked files are reset;  ?? = new files and folders are deleted"
echo

if [ ! -t 0 ]; then
  echo "no terminal to ask on: nothing was changed" >&2
  exit 1
fi
printf 'Type "yes" to reset and delete these changes: '
read -r answer
if [ "$answer" != "yes" ]; then
  echo "cancelled: nothing was changed"
  exit 1
fi

for r in "${todo[@]}"; do
  git -C "$r" reset -q --hard
  git -C "$r" clean -qfd
  echo "$(basename "$r"): reset"
done
