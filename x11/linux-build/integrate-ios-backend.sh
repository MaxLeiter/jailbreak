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
# IMPORTANT: the no-/work/x11 fallback patch for meta-context-main.c must stay out of the
# real backend path — meta-context-main-ios-backend.patch supersedes that fallback by
# providing the real MetaBackendIOS branch for the same spot.
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
   "$WL"/meta-onscreen-ios.[ch] \
   "$WL"/meta-clutter-backend-ios.[ch] \
   "$WL"/meta-stage-ios.[ch] \
   "$WL"/meta-seat-ios.[ch] \
   "$WL"/meta-keymap-ios.[ch] \
   "$WL"/meta-virtual-input-device-ios.[ch] \
   "$WL"/meta-input-ios.[ch] \
   "$WL"/meta-backend-ios.[ch] \
   "$WL"/meta-wayland-iosurface.[ch] \
   "$MUTTER_ROOT/src/backends/ios/"
# The backend .c files #include "backends/ios/xios-glue-stub.h" (the self-contained glue API
# contract) — stage it alongside them. Its extern declarations resolve at link time against
# libxios_glue.a. (xios-glue-include/ is ALSO staged below and put on the -I path, but nothing
# #includes those canonical headers directly; the stub is the single header the .c use.)
cp "$WL"/xios-glue-stub.h "$MUTTER_ROOT/src/backends/ios/"

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
         meta-wayland-xdg-first-buffer-showing \
         meta-wayland-text-input-osk-ios \
         meson-ios-backend; do
  echo "   $p.patch"
  patch -p1 -d "$MUTTER_ROOT" --forward -r - < "$LB/patches/mutter/$p.patch" \
    || { echo "FAIL: $p.patch did not apply cleanly"; exit 1; }
done

echo "==> MetaBackendIOS integrated into $MUTTER_ROOT"
echo "    reminder: do not apply the mutter-gir fallback patch on the real backend path."
