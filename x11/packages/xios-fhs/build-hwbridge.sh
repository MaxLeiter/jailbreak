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
if [ -d /work/x11/packages/xios-fhs ]; then
  SRC=/work/x11/packages/xios-fhs
else
  SRC=/work/xios-fhs
fi
OUT=/out
mkdir -p "$OUT"

MEMO_TARGET="${XIOS_MEMO_TARGET:-${MEMO_TARGET:-iphoneos-arm64-rootless}}"
MEMO_CFVER="${XIOS_MEMO_CFVER:-${MEMO_CFVER:-1900}}"
if [ "${XIOS_PREFIX+x}" = x ]; then
  TARGET_PREFIX="$XIOS_PREFIX"
elif [ "$MEMO_TARGET" = "iphoneos-arm64-rootless" ]; then
  TARGET_PREFIX="/var/jb"
else
  TARGET_PREFIX=""
fi
TARGET_SUBPREFIX="${XIOS_SUBPREFIX:-/usr}"
TARGET_MIN_IOS="${XIOS_DEFAULT_MIN_IOS:-16.0}"
TARGET_INSTALL_PREFIX="$TARGET_PREFIX$TARGET_SUBPREFIX"
[ -n "$TARGET_PREFIX" ] || TARGET_INSTALL_PREFIX="$TARGET_SUBPREFIX"
TARGET_SYS_ROOT="${XIOS_SYS_ROOT:-}"
if [ -z "$TARGET_SYS_ROOT" ]; then
  if [ -n "$TARGET_PREFIX" ]; then TARGET_SYS_ROOT="$TARGET_PREFIX/sys"; else TARGET_SYS_ROOT="/sys"; fi
fi
TARGET_PACKAGE_PATH_PREFIX="${XIOS_PACKAGE_PATH_PREFIX:-$TARGET_PREFIX}"
XIOS_PROTOCOL_INCLUDE="${XIOS_PROTOCOL_INCLUDE:-$SRC/../../apps/shared}"
[ -f "$XIOS_PROTOCOL_INCLUDE/XiosProtocol.h" ] || {
  echo "!! canonical XiosProtocol.h not found at $XIOS_PROTOCOL_INCLUDE" >&2
  echo "   mount x11 at /work/x11 and set SRC=/work/x11/packages/xios-fhs" >&2
  exit 1
}

SYSROOT_ROOT="$PROC/build_base/$MEMO_TARGET/$MEMO_CFVER"
SYSROOT="$SYSROOT_ROOT$TARGET_INSTALL_PREFIX"
[ -d "$SYSROOT/include/glib-2.0" ] || { echo "!! glib not in sysroot: $SYSROOT"; exit 1; }

echo "==> locate cross clang + tools"
CC=""
for cand in aarch64-apple-darwin-clang arm64-apple-darwin-clang aarch64-apple-darwin20-clang; do
  command -v "$cand" >/dev/null 2>&1 && { CC="$cand"; break; }
done
[ -n "$CC" ] || { echo "!! cross clang not found"; exit 1; }
SDK="$(dirname "$(command -v "$CC")")/../SDK/iPhoneOS.sdk"
LDID="$(command -v ldid || true)"

export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig:$SYSROOT/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT_ROOT"

CFLAGS=(
  -arch arm64
  -isysroot "$SDK"
  -miphoneos-version-min="$TARGET_MIN_IOS"
  -O2
  -Wall
  -Wextra
  -Wno-unused-parameter
  "-I$XIOS_PROTOCOL_INCLUDE"
  "-DDEFAULT_SYS_ROOT=\"$TARGET_SYS_ROOT\""
)
# glib/gio/gobject/libintl.8 are referenced as @rpath but the binaries carry no
# LC_RPATH, so @rpath doesn't resolve on device without DYLD_LIBRARY_PATH. Bake an
# LC_RPATH pointing at where those libs live on device. Set at link
# time so it survives the later install_name_tool + ldid fixups.
LDRPATH="-Wl,-rpath,$TARGET_INSTALL_PREFIX/lib"
# CoreFoundation for the IOPS dictionaries; IOKit/BackBoardServices/AVFoundation come via
# dlopen. -lobjc for the objc_msgSend torch calls (AVCaptureDevice).
DEPFLAGS="$(pkg-config --cflags --libs gio-2.0 gio-unix-2.0) -L$SYSROOT/lib -framework CoreFoundation -lobjc $LDRPATH"
SENSOR_DEPFLAGS="$(pkg-config --cflags --libs gio-2.0 gio-unix-2.0) -L$SYSROOT/lib -framework CoreMotion -lobjc $LDRPATH"
echo "   target=$MEMO_TARGET/$MEMO_CFVER prefix=${TARGET_PREFIX:-/} sys=$TARGET_SYS_ROOT"
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
$CC "${CFLAGS[@]}" "$s" $DEPFLAGS -o "$o"
fixup_and_sign "$o" "$SRC/entitlements.plist"

s="$SRC/src/xios-sensord.m"
o2="$OUT/xios-sensord"
echo "==> build xios-sensord"
# shellcheck disable=SC2086
$CC "${CFLAGS[@]}" "$s" $SENSOR_DEPFLAGS -o "$o2"
fixup_and_sign "$o2" "$SRC/sensor-entitlements.plist"

# Drop the binary into the package tree so package-hwbridge (or make-repo) can pack it.
DEST="$SRC$TARGET_PACKAGE_PATH_PREFIX$TARGET_SUBPREFIX/libexec"
mkdir -p "$DEST"
cp -a "$OUT/xios-hwbridged" "$DEST/xios-hwbridged"
cp -a "$OUT/xios-sensord" "$DEST/xios-sensord"

echo "==> done -> $OUT/xios-hwbridged $OUT/xios-sensord (+ staged into var/jb/usr/libexec)"
