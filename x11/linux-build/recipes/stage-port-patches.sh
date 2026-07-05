#!/usr/bin/env bash
# Copy a quilt-style ports/<pkg>/patches/series into Procursus build_patch/<pkg>.
set -euo pipefail

pkg="${1:?usage: stage-port-patches.sh <pkg> [ports-root] [dest-root]}"
ports_root="${2:-/work/ports}"
dest_root="${3:-build_patch}"
patch_dir="$ports_root/$pkg/patches"
series="$patch_dir/series"
dest="$dest_root/$pkg"

[ -f "$series" ] || {
  echo "stage-port-patches: missing $series" >&2
  exit 1
}

rm -rf "$dest"
mkdir -p "$dest"

while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"
  set -- $line
  [ "$#" -gt 0 ] || continue
  patch="$patch_dir/$1"
  [ -f "$patch" ] || {
    echo "stage-port-patches: missing $patch" >&2
    exit 1
  }
  cp -v "$patch" "$dest/"
done < "$series"
