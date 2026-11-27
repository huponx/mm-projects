#!/usr/bin/env bash
# Usage: unzip-prune.sh ARCHIVE TARGET [IGNORED_NAME...]
#
# Makes TARGET match the archive: removes the files (and then-empty folders) in TARGET that are not in the
# archive, i.e. what was deleted from the folder before it was zipped. Never touches a .git folder, an
# *.ipx archive, or anything under the ignored names (local state and caches that `make zip` leaves out).
set -euo pipefail

archive=${1:?archive}
target=${2:?target}
shift 2
ignored=("$@")

export LC_ALL=C
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Entries of the archive: files and folders (folders end in "/"), without the ones in a .git folder.
unzip -Z1 "$archive" | grep -v -E '(^|/)\.git(/|$)' >"$tmp/entries" || true
grep -v '/$' "$tmp/entries" | sort -u >"$tmp/arch_files"
grep '/$' "$tmp/entries" | sed 's|/$||' | sort -u >"$tmp/arch_dirs"
# A folder is also there when only a file inside it is listed.
sed -n 's|/[^/]*$||p' "$tmp/arch_files" | awk '{ n = split($0, p, "/"); s = ""; for (i = 1; i <= n; i++) { s = s (i > 1 ? "/" : "") p[i]; print s } }' >>"$tmp/arch_dirs"
sort -u -o "$tmp/arch_dirs" "$tmp/arch_dirs"

prune=(-name .git)
for n in "${ignored[@]}"; do prune+=(-o -name "$n"); done

cd "$target"
find . \( "${prune[@]}" \) -prune -o ! -type d ! -name '*.ipx' -print | sed 's|^\./||' | sort -u >"$tmp/disk_files"
find . \( "${prune[@]}" \) -prune -o -type d -print | sed 's|^\./||; /^\.$/d' | sort -u >"$tmp/disk_dirs"

removed=0
while IFS= read -r f; do
  rm -f -- "$f"
  removed=$((removed + 1))
done < <(comm -23 "$tmp/disk_files" "$tmp/arch_files")

dirs=0
# Deepest first, so a folder that only held removed files is empty by then; rmdir leaves a folder that is not empty.
while IFS= read -r d; do
  if rmdir -- "$d" 2>/dev/null; then dirs=$((dirs + 1)); fi
done < <(comm -23 "$tmp/disk_dirs" "$tmp/arch_dirs" | sort -r)

echo "removed $removed file(s) and $dirs folder(s) that are not in the archive"
