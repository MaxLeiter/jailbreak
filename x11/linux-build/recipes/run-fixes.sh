#!/usr/bin/env bash
# run-fixes.sh <fix-script-name> <source-dir> [extra args...]
#
# Runs a *-ios-fixes.sh against an extracted source tree and FAILS if it changed fewer files than the
# minimum recorded in fix-min-files.txt. A fix script that matches nothing exits 0 and "applies" nothing;
# that is how a port silently rots across an upstream bump. The minimum is the number of files the script
# touched on the version it was last ported to. A script missing from the table is a hard error too.
set -euo pipefail

name=${1:?usage: run-fixes.sh <fix-script-name> <source-dir> [args...]}
src=${2:?usage: run-fixes.sh <fix-script-name> <source-dir> [args...]}
shift 2
here="$(cd "$(dirname "$0")" && pwd)"

# A re-run of `make <unit>-setup` on an already-patched tree must not re-apply (many hunks are not idempotent and the
# changed-file count would legitimately be lower): a stamp marks a tree this script already fixed successfully.
stamp="$src/.xios-fixes-$name"
if [ -e "$stamp" ]; then echo "run-fixes.sh: $name already applied to $src (stamp), skipping"; exit 0; fi

min=$(awk -v n="$name" '$1==n {print $2}' "$here/fix-min-files.txt")
[ -n "$min" ] || { echo "run-fixes.sh: $name has no entry in fix-min-files.txt" >&2; exit 2; }

snap() {
  (cd "$src" && find . -type f \( -name '*.txt' -o -name '*.cmake' -o -name '*.cpp' -o -name '*.h' -o -name '*.hpp' \
      -o -name '*.qml' -o -name '*.in' -o -name '*.xml' -o -name '*.json' -o -name '*.mm' -o -name '*.js' \) \
      -not -path './po/*' -print0 | sort -z | xargs -0 cksum)
}
before=$(mktemp); after=$(mktemp)
trap 'rm -f "$before" "$after"' EXIT
snap > "$before"
bash "$here/$name" "$src" "$@"
snap > "$after"
changed=$(diff "$before" "$after" | grep -c '^>' || true)
echo "run-fixes.sh: $name changed $changed file(s) (minimum $min)"
if [ "$changed" -lt "$min" ]; then
  echo "ERROR: $name changed $changed < $min files: hunks no longer match this source version (silent no-op). Re-port it." >&2
  exit 1
fi
touch "$stamp"
