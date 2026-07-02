#!/usr/bin/env bash
# Build xios-hwbridged + xios-sensord for rootless iOS (the xios-fhs daemons).
#
# Same pattern as wayland/build-session-stubs.sh: a pure GLib/GDBus daemon cross-compiled
# against the Procursus iOS sysroot that built glib. It additionally links CoreFoundation
# (the IOKit power-source dictionaries are CF types); IOKit and BackBoardServices themselves
# are dlopen'd at runtime, so no private tbd/headers are needed at build time.
#
# Runs INSIDE the Procursus cross image against the warm volume that built glib, e.g.:
#   docker run --rm --platform linux/arm64 \
#     -v procursus-vol-shell:/work/Procursus \
#     -v "$PWD:/work/xios-fhs" -v "$PWD/out:/out" \
#     --entrypoint bash procursus-xbuild:bookworm-arm64 /work/xios-fhs/build-hwbridge.sh
set -euo pipefail
umask 022

PROC=/work/Procursus
SRC=/work/xios-fhs
OUT=/out
mkdir -p "$OUT"

SYSROOT="$PROC/build_base/iphoneos-arm64-rootless/1900/var/jb/usr"
[ -d "$SYSROOT/include/glib-2.0" ] || { echo "!! glib not in sysroot: $SYSROOT"; exit 1; }

echo "==> locate cross clang + tools"
CC=""
for cand in aarch64-apple-darwin-clang arm64-apple-darwin-clang aarch64-apple-darwin20-clang; do
  command -v "$cand" >/dev/null 2>&1 && { CC="$cand"; break; }
done
[ -n "$CC" ] || { echo "!! cross clang not found"; exit 1; }
SDK="$(dirname "$(command -v "$CC")")/../SDK/iPhoneOS.sdk"
LDID="$(command -v ldid || true)"

SYSROOT_ROOT="$PROC/build_base/iphoneos-arm64-rootless/1900"
export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig:$SYSROOT/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT_ROOT"

CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0 -O2 -Wall -Wextra -Wno-unused-parameter"
# CoreFoundation for the IOPS dictionaries; IOKit/BackBoardServices come via dlopen.
DEPFLAGS="$(pkg-config --cflags --libs gio-2.0 gio-unix-2.0) -L$SYSROOT/lib -framework CoreFoundation"
SENSOR_DEPFLAGS="$(pkg-config --cflags --libs gio-2.0 gio-unix-2.0) -L$SYSROOT/lib -framework CoreMotion -lobjc"
echo "   CC=$CC  SDK=$SDK  pkgconfig-libdir=$PKG_CONFIG_LIBDIR"

INT=""
for cand in install_name_tool aarch64-apple-darwin-install_name_tool arm64-apple-darwin-install_name_tool; do
  command -v "$cand" >/dev/null 2>&1 && { INT="$cand"; break; }
done
OTOOL=""
for cand in otool aarch64-apple-darwin-otool arm64-apple-darwin-otool; do
  command -v "$cand" >/dev/null 2>&1 && { OTOOL="$cand"; break; }
done

fixup_and_sign() {
  local bin="$1" ent="$2"

  # install_name_tool: the linker resolves glib's dependency to @rpath/libintl.dylib, an
  # unversioned dev-only symlink not shipped at runtime; rewrite it to the versioned
  # libintl.8.dylib the device actually has. Must run BEFORE ldid (it invalidates the
  # signature). Same fixup the session stubs do.
  if [ -n "$INT" ] && [ -n "$OTOOL" ] && "$OTOOL" -L "$bin" 2>/dev/null | grep -q '@rpath/libintl.dylib'; then
    "$INT" -change @rpath/libintl.dylib @rpath/libintl.8.dylib "$bin"
    echo "   $(basename "$bin"): @rpath/libintl.dylib -> @rpath/libintl.8.dylib"
  fi

  if [ -n "$LDID" ]; then
    if [ -f "$ent" ]; then
      "$LDID" -S"$ent" "$bin"
    else
      "$LDID" -S "$bin"
    fi
  fi
  file "$bin" | sed 's/^/   /'
}

s="$SRC/src/xios-hwbridged.c"
o="$OUT/xios-hwbridged"
echo "==> build xios-hwbridged"
# shellcheck disable=SC2086
$CC $CFLAGS "$s" $DEPFLAGS -o "$o"
fixup_and_sign "$o" "$SRC/entitlements.plist"

s="$SRC/src/xios-sensord.m"
o2="$OUT/xios-sensord"
echo "==> build xios-sensord"
# shellcheck disable=SC2086
$CC $CFLAGS "$s" $SENSOR_DEPFLAGS -o "$o2"
fixup_and_sign "$o2" "$SRC/sensor-entitlements.plist"

# Drop the binary into the package tree so package-hwbridge (or make-repo) can pack it.
DEST="$SRC/var/jb/usr/libexec"
mkdir -p "$DEST"
cp -a "$OUT/xios-hwbridged" "$DEST/xios-hwbridged"
cp -a "$OUT/xios-sensord" "$DEST/xios-sensord"

echo "==> done -> $OUT/xios-hwbridged $OUT/xios-sensord (+ staged into var/jb/usr/libexec)"
