#!/usr/bin/env bash
# Weak-links a set of (absent-on-iOS) dylib references inside every Mach-O
# in a Procursus .deb, re-signs the modified dylibs, and repacks the deb in
# place. HOST (macOS) tool.
#
# mutter 46 can't build without X11 (have_x11 is hardcoded; see
# docs/mutter-on-iosc.md "build5"), so libmutter and its runtime closure
# strong-link X11/xcb extension libs absent on the iPad (libxcb-randr.0,
# libxcb-res.0, libxcb-xkb.1, ...). A strong load command to a missing lib
# makes dyld hard-fail; this flips those references to LC_LOAD_WEAK_DYLIB
# (tools/macho-weaken.py) since the X11 code is dead on our Wayland-only
# MetaBackendIOS, so the null-bound symbols are never called. Genuinely
# present libs (libxkbcommon.0, libxcb.1) are left strong.
#
# Host counterpart to mutter.mk's in-container weaken, which only covers
# libmutter itself; use this for dep-closure debs built by other recipes
# (currently libxkbcommon-dev: libxkbcommon-x11.0.dylib -> libxcb-xkb.1).
# Idempotent: an already-weak command is skipped.
#
# Usage:
#   weaken-deb.sh <deb> <lib-substr> [<lib-substr> ...]
# Example:
#   weaken-deb.sh out/libxkbcommon-dev_1.7.0_iphoneos-arm64.deb libxcb-xkb.1.dylib
#
# Requires: ar, zstd, tar (bsdtar), codesign, md5, python3 (+ tools/macho-weaken.py alongside).
set -euo pipefail

DEB=${1:?usage: weaken-deb.sh <deb> <lib-substr> [<lib-substr> ...]}
shift
[ $# -ge 1 ] || { echo "FAIL: give at least one lib-name substring to weaken"; exit 2; }
TARGETS=("$@")

HERE=$(cd "$(dirname "$0")" && pwd)
WEAKEN="$HERE/macho-weaken.py"
[ -f "$WEAKEN" ] || { echo "FAIL: $WEAKEN missing"; exit 2; }
DEB=$(cd "$(dirname "$DEB")" && pwd)/$(basename "$DEB")
[ -f "$DEB" ] || { echo "FAIL: $DEB not found"; exit 2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

ar x "$DEB"
mkdir data ctl
zstd -q -d -c data.tar.zst | tar x -C data
zstd -q -d -c control.tar.zst | tar x -C ctl

changed=0
while IFS= read -r f; do
  out=$(python3 "$WEAKEN" "$f" "${TARGETS[@]}" | tail -1)
  # output: "<path>: <N> load command(s) made weak, <M> import(s) made weak"
  lc=$(printf '%s' "$out" | sed -E 's/.*: ([0-9]+) load command.*/\1/')
  imp=$(printf '%s' "$out" | sed -E 's/.*, ([0-9]+) import.*/\1/')
  n=$(( ${lc:-0} + ${imp:-0} ))
  if [ "$n" -gt 0 ]; then
    codesign -f -s - "$f"        # re-cover the mutated Mach-O (adhoc, matches Procursus)
    echo "  weakened+resigned: ${f#"$WORK"/data/}  (${lc:-0} load cmd, ${imp:-0} import)"
    changed=$((changed + n))
  fi
done < <(find data -type f -name '*.dylib')

if [ "$changed" -eq 0 ]; then
  echo "no matching load commands/imports in $(basename "$DEB") — nothing to do"
  exit 0
fi

# regenerate md5sums (dpkg format: relative path, no leading ./) + Installed-Size
( cd data && find . -type f | sed 's|^\./||' | LC_ALL=C sort | while read -r p; do
    printf '%s  %s\n' "$(md5 -q "$p")" "$p"; done ) > ctl/md5sums
BYTES=$(cd data && find . -type f -exec stat -f '%z' {} + | awk '{s+=$1} END{print s}')
if grep -q '^Installed-Size:' ctl/control; then
  sed -i '' "s/^Installed-Size: .*/Installed-Size: $(( (BYTES + 1023) / 1024 ))/" ctl/control
fi

# repack root:root, ./-prefixed, and reassemble in the original member order. --no-xattrs is
# CRITICAL: files that passed through a Docker bind mount carry
# LIBARCHIVE.xattr.com.docker.grpcfuse.ownership pax headers, which abort the device's (older)
# dpkg tar ("paste subprocess killed by signal (Broken pipe: 13)"). Strip macOS metadata too.
export COPYFILE_DISABLE=1
tar --no-xattrs --no-mac-metadata --uid 0 --gid 0 --uname root --gname root -cf control.tar -C ctl .
zstd -q -19 -f control.tar -o control.tar.zst
tar --no-xattrs --no-mac-metadata --uid 0 --gid 0 --uname root --gname root -cf data.tar -C data .
zstd -q -19 -f data.tar -o data.tar.zst
rm -f "$DEB"
ar rc "$DEB" debian-binary control.tar.zst data.tar.zst

echo "repacked $(basename "$DEB") ($changed weakening(s): load commands + imports)"
