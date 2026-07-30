#!/usr/bin/env bash
# Stages the MetaBackendIOS sources + applies the integration patches into a mutter 46 source
# tree, so the mutter build compiles gnome-shell's iOS/IOSurface backend.
#
# Run this in mutter-setup after the tarball is extracted and before meson configure.
#
# The no-/work/x11 fallback patch for meta-context-main.c must stay out of the real backend
# path — meta-context-main-ios-backend.patch supersedes it with the real MetaBackendIOS branch
# at the same spot.
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
   "$WL"/meta-clipboard-ios.[ch] \
   "$WL"/iosc-clipboard-bridge.[ch] \
   "$WL"/meta-backend-ios.[ch] \
   "$WL"/meta-wayland-iosurface.[ch] \
   "$MUTTER_ROOT/src/backends/ios/"
# The backend .c files #include "backends/ios/xios-glue-stub.h", whose extern declarations
# resolve at link time against libxios_glue.a. xios-glue-include/ is also staged below and put
# on the -I path, but nothing #includes those headers directly — the stub is what the .c use.
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
