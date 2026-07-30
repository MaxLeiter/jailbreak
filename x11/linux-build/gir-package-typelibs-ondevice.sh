#!/bin/sh
# Build xios-gnome-typelibs from the on-device-generated typelibs (the g-ir-scanner
# artifacts that no cross-built library deb ships on iOS). Captures the full working set.
set -e
VER="0.2.0"
GIR=/var/jb/usr/lib/girepository-1.0
STAGE=/var/jb/tmp/xios-gnome-typelibs-build
rm -rf "$STAGE"
mkdir -p "$STAGE/DEBIAN" "$STAGE/var/jb/usr/lib/girepository-1.0"

# Harvest every typelib NOT owned by another installed package (base GLib/freedesktop
# typelibs come from gir1.2-glib-2.0 / gir1.2-freedesktop and are skipped).
COUNT=0
for t in "$GIR"/*.typelib; do
  bn=$(basename "$t")
  owner=$(dpkg -S "$GIR/$bn" 2>/dev/null | cut -d: -f1)
  if [ -z "$owner" ] || [ "$owner" = "xios-gnome-typelibs" ]; then
    cp -a "$t" "$STAGE/var/jb/usr/lib/girepository-1.0/"
    COUNT=$((COUNT+1))
  fi
done
echo "harvested $COUNT typelibs"

cat > "$STAGE/DEBIAN/control" <<CTRL
Package: xios-gnome-typelibs
Name: Xios GNOME desktop typelibs
Version: $VER
Architecture: iphoneos-arm64
MinimumOSVersion: 16.0.0
Maintainer: Max Leiter <maxwell.leiter@gmail.com>
Author: Max Leiter <maxwell.leiter@gmail.com>
Depends: libgirepository-1.0-1
Section: X11
Priority: optional
Description: On-device-regenerated introspection typelibs for the Xios GNOME desktop
 The complete set of GObject-Introspection typelibs the GNOME Shell 46 session
 needs at runtime that no cross-built library deb ships on iOS (the cross build
 cannot exec g-ir-scanner, so every lib defers its typelib to an on-device
 native scan; see gir-build-lib-ondevice.sh). Regenerated from source with
 g-ir-scanner on the device and captured here so a clean package install
 reproduces a booting GNOME with zero hand-staged files.
CTRL

# NOTE on Depends: runtime consumers only need libgirepository-1.0-1, the .typelib
# loader. Do NOT re-add gobject-introspection: that is the GENERATOR (g-ir-scanner /
# g-ir-compiler), it Depends on clang, and clang drags in the whole ~967 MB llvm-16
# chain (libllvm16 + llvm-16-dev + libclang-common-16-dev + ld64 + odcctools). Since
# this package ships the typelibs pre-built, that made every GNOME-flavor install pull
# ~1 GB of compiler nothing ever execs. The on-device scan is a BUILD step run from
# gir-build-lib-ondevice.sh, so the toolchain belongs in the build environment, not in
# a runtime Depends. Verified 2026-07-29: this package ships 43 .typelib files and no
# scanner invocation happens at session start.

# md5sums
( cd "$STAGE" && find var -type f -exec md5sum {} \; > DEBIAN/md5sums )

OUT=/var/jb/tmp/xios-gnome-typelibs_${VER}_iphoneos-arm64.deb
dpkg-deb -Zgzip -b "$STAGE" "$OUT" >/dev/null
echo "built $OUT"
dpkg-deb -I "$OUT" | grep -E "Package|Version|Installed-Size" || true
echo "--- files ---"
dpkg-deb -c "$OUT" | awk '{print $NF}' | grep typelib | wc -l
