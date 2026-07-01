#!/usr/bin/env bash
# build-backend-check.sh — OFF-DEVICE compile check for the MetaBackendIOS pieces
# (src/backends/ios/*.c: monitor manager, input, the Wayland IOSurface buffer type).
#
# These are new mutter backend files. Rather than wire them into meson yet, we compile
# each against the mutter 46 source tree with the EXACT strict flags + include set mutter
# uses for its own backend objects — harvested from ninja's compile command for
# backends/meta-monitor-manager-dummy.c.o (so the check tracks the real build). A clean
# .o proves the vtable overrides + struct usage match the 46.0 ABI. Same philosophy as
# build-cogl-smoke.sh (which is compile+link, because its winsys symbols are exported).
#
#   docker run --rm --platform linux/arm64 -v procursus-vol-gtk:/work/Procursus \
#     -v "$PWD/../wayland:/src:ro" procursus-xbuild:bookworm-arm64 \
#     -c 'bash /src/../linux-build/build-backend-check.sh meta-monitor-manager-ios.c'
#
# Args: one or more source basenames (in /src). Headers in /src are staged alongside.
set -euo pipefail

M=/work/Procursus/build_work/iphoneos-arm64-rootless/1900/mutter
B=$M/build
SRCDIR=${SRCDIR:-/src}
STAGE=/tmp/ios-check/backends/ios
REF_OBJ='src/libmutter-14.0.dylib.p/backends_meta-monitor-manager-dummy.c.o'
REF_SRC='../src/backends/meta-monitor-manager-dummy.c'

[ -d "$B" ] || { echo "FAIL: mutter build tree not at $B"; exit 2; }

# Stage the flat wayland/ sources into the eventual in-tree layout so that the in-tree
# include paths ("backends/ios/...") resolve against them.
rm -rf /tmp/ios-check && mkdir -p "$STAGE"
cp "$SRCDIR"/*.h "$STAGE"/ 2>/dev/null || true

# Generate wayland server-protocol headers from any real protocol .xml in /src (skip the
# codesign entitlement plists that share the .xml extension). Uses the native (Linux) scanner
# the W0 wayland track built into the volume.
NATIVE_SCANNER=/work/Procursus/build_work/iphoneos-arm64-rootless/1900/wayland/native-root/bin/wayland-scanner
for xml in "$SRCDIR"/*.xml; do
  [ -f "$xml" ] || continue
  grep -q "<protocol" "$xml" || continue
  base=$(basename "${xml%.xml}")
  if [ -x "$NATIVE_SCANNER" ] && "$NATIVE_SCANNER" server-header "$xml" \
       "$STAGE/$base-server-protocol.h" 2>/dev/null; then
    echo "==> scanned $base-server-protocol.h"
  fi
done

# Harvest mutter's own compile command for a backend object (exact flags + includes).
cd "$B"
BASECMD=$(ninja -t commands "$REF_OBJ" 2>/dev/null | tail -1)
[ -n "$BASECMD" ] || { echo "FAIL: could not harvest compile command from ninja"; exit 2; }

rc=0
for src in "$@"; do
  cp "$SRCDIR/$src" "$STAGE/$src"
  obj="/tmp/ios-check/${src%.c}.o"
  cmd=$(printf '%s' "$BASECMD" \
        | sed "s#$REF_OBJ#$obj#g; s#$REF_SRC#$STAGE/$src#g")
  # prepend the stage dir so backends/ios/*.h resolve; keep all real -I flags after it.
  cmd=${cmd/ / -I/tmp/ios-check }
  echo "==> compile-check: $src"
  if eval "$cmd" && [ -f "$obj" ]; then
    echo "    OK  -> $(basename "$obj") ($(wc -c < "$obj") bytes)"
  else
    echo "    FAIL: $src did not compile clean"
    rc=1
  fi
done

exit $rc
