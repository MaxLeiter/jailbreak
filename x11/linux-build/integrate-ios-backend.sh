#!/usr/bin/env bash
# integrate-ios-backend.sh — stage the MetaBackendIOS sources + apply the integration patches
# into a mutter 46 source tree, so the mutter build compiles gnome-shell's iOS/IOSurface backend.
#
# Run this in mutter-setup AFTER the tarball is extracted and BEFORE meson configure. It:
#   1. copies the backends/ios/* sources (the whole MetaBackendIOS) into src/backends/ios/
#   2. copies the iosc_iosurface protocol into src/wayland/protocol/
#   3. stages libxios_glue.a + its headers into src/backends/ios/
#   4. applies the 4 integration patches (buffer type, context-main backend branch, wayland
#      iosurface-init, meson wiring)
#
# IMPORTANT: mutter.mk's perl -0pi patch of meta-context-main.c (the g_assert_not_reached
# insertion for the wayland+no-native case) MUST BE REMOVED — meta-context-main-ios-backend.patch
# supersedes it (it provides the real MetaBackendIOS branch for that same spot).
#
#   integrate-ios-backend.sh <mutter-src-root> [repo-x11-dir]
set -euo pipefail

MUTTER_ROOT=${1:?usage: integrate-ios-backend.sh <mutter-src-root> [repo-x11-dir]}
REPO=${2:-$(cd "$(dirname "$0")/.." && pwd)}    # the x11 dir (contains wayland/ + linux-build/)
WL=$REPO/wayland
LB=$REPO/linux-build
OUT=$WL/out

[ -d "$MUTTER_ROOT/src" ]        || { echo "FAIL: $MUTTER_ROOT is not a mutter source tree"; exit 2; }
[ -f "$OUT/libxios_glue.a" ]     || { echo "FAIL: $OUT/libxios_glue.a missing (build libxios_glue first)"; exit 2; }

echo "==> stage src/backends/ios/ (the MetaBackendIOS sources)"
mkdir -p "$MUTTER_ROOT/src/backends/ios"
cp "$WL"/meta-monitor-manager-ios.[ch] \
   "$WL"/meta-renderer-ios.[ch] \
   "$WL"/meta-clutter-backend-ios.[ch] \
   "$WL"/meta-stage-ios.[ch] \
   "$WL"/meta-seat-ios.[ch] \
   "$WL"/meta-keymap-ios.[ch] \
   "$WL"/meta-virtual-input-device-ios.[ch] \
   "$WL"/meta-input-ios.[ch] \
   "$WL"/meta-backend-ios.[ch] \
   "$WL"/meta-wayland-iosurface.[ch] \
   "$MUTTER_ROOT/src/backends/ios/"
# (xios-glue-stub.h is NOT copied — the backend .c use the 3 canonical headers from
#  xios-glue-include/, staged below; the stub is only the off-device compile-check shim.)

echo "==> stage the iosc_iosurface protocol"
mkdir -p "$MUTTER_ROOT/src/wayland/protocol"
cp "$WL/iosc-iosurface.xml" "$MUTTER_ROOT/src/wayland/protocol/iosc-iosurface.xml"

echo "==> stage libxios_glue.a + headers"
cp "$OUT/libxios_glue.a" "$MUTTER_ROOT/src/backends/ios/libxios_glue.a"
rm -rf "$MUTTER_ROOT/src/backends/ios/xios-glue-include"
cp -a "$OUT/xios-glue-include" "$MUTTER_ROOT/src/backends/ios/xios-glue-include"

echo "==> apply integration patches"
for p in meta-wayland-buffer-iosurface \
         meta-context-main-ios-backend \
         meta-compositor-ios-server \
         meta-wayland-iosurface-init \
         meson-ios-backend; do
  echo "   $p.patch"
  patch -p1 -d "$MUTTER_ROOT" --forward -r - < "$LB/patches/mutter/$p.patch" \
    || { echo "FAIL: $p.patch did not apply cleanly"; exit 1; }
done

echo "==> MetaBackendIOS integrated into $MUTTER_ROOT"
echo "    reminder: remove mutter.mk's perl meta-context-main g_assert patch (superseded)."
