#!/usr/bin/env bash
# Build the libgsound STUB (see gsound-stub/gsound-stub.c) for rootless iOS and install it into
# the Procursus volume sysroot so gnome-control-center (sound panel) and gnome-bluetooth resolve
# `dependency('gsound')`. Avoids cross-building libcanberra. Stages a runtime deb tree into /out.
#
#   docker run --rm --platform linux/arm64 \
#     -v procursus-vol-shell:/work/Procursus \
#     -v "$PWD/gsound-stub:/work/gsound-stub:ro" \
#     -v "$PWD/build-gsound-stub.sh:/work/build-gsound-stub.sh:ro" -v "$PWD/out:/out" \
#     --entrypoint bash procursus-xbuild:bookworm-arm64 /work/build-gsound-stub.sh
set -euo pipefail
umask 022
PROC=/work/Procursus
SRC=/work/gsound-stub
OUT=/out
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
TARGET_PACKAGE_PATH_PREFIX="${XIOS_PACKAGE_PATH_PREFIX:-$TARGET_PREFIX}"
TARGET_INSTALL_PREFIX="$TARGET_PREFIX$TARGET_SUBPREFIX"
[ -n "$TARGET_PREFIX" ] || TARGET_INSTALL_PREFIX="$TARGET_SUBPREFIX"
SYSROOT_ROOT="$PROC/build_base/$MEMO_TARGET/$MEMO_CFVER"
SYSROOT="$SYSROOT_ROOT$TARGET_INSTALL_PREFIX"

CC=""
for cand in aarch64-apple-darwin-clang arm64-apple-darwin-clang; do
  command -v "$cand" >/dev/null 2>&1 && { CC="$cand"; break; }
done
[ -n "$CC" ] || { echo "!! cross clang not found"; exit 1; }
SDK="$(dirname "$(command -v "$CC")")/../SDK/iPhoneOS.sdk"
LDID="$(command -v ldid || true)"

export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig:$SYSROOT/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT_ROOT"
CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=$TARGET_MIN_IOS -O2 -Wall -Wextra -Wno-unused-parameter"
GLIB_FLAGS="$(pkg-config --cflags --libs gio-2.0 gobject-2.0 glib-2.0)"

DYLIB=libgsound.0.dylib
echo "==> compiling $DYLIB"
# shellcheck disable=SC2086
$CC $CFLAGS -dynamiclib -fvisibility=default \
    -install_name @rpath/$DYLIB -compatibility_version 1.0.0 -current_version 1.0.3 \
    -I"$SRC" "$SRC/gsound-stub.c" $GLIB_FLAGS -L"$SYSROOT/lib" \
    -Wl,-rpath,"$TARGET_INSTALL_PREFIX/lib" -o "/tmp/$DYLIB"
[ -n "$LDID" ] && "$LDID" -S "/tmp/$DYLIB"
file "/tmp/$DYLIB" | sed 's/^/   /'

echo "==> installing into volume sysroot ($SYSROOT)"
install -m 0755 "/tmp/$DYLIB" "$SYSROOT/lib/$DYLIB"
ln -sf "$DYLIB" "$SYSROOT/lib/libgsound.dylib"    # unversioned dev symlink for -lgsound
# Upstream install_headers() puts all three at $includedir root; consumers use <gsound.h>,
# which #includes "gsound-context.h"/"gsound-attr.h" from the same dir.
cp -v "$SRC/gsound.h" "$SRC/gsound-context.h" "$SRC/gsound-attr.h" "$SYSROOT/include/"
cat > "$SYSROOT/lib/pkgconfig/gsound.pc" <<PC
prefix=$TARGET_INSTALL_PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: gsound
Description: libgsound stub for iOS (AudioToolbox event sounds; no libcanberra)
Version: 1.0.3
Requires: glib-2.0 gobject-2.0 gio-2.0
Libs: -L\${libdir} -lgsound
Cflags: -I\${includedir}
PC
echo "   installed gsound.pc + headers + $DYLIB (+ symlink)"

echo "==> staging runtime tree -> $OUT/gsound-stub-tree"
DEST="$OUT/gsound-stub-tree$TARGET_PACKAGE_PATH_PREFIX$TARGET_SUBPREFIX/lib"
mkdir -p "$DEST"
install -m 0755 "/tmp/$DYLIB" "$DEST/$DYLIB"
ln -sf "$DYLIB" "$DEST/libgsound.dylib"
echo "==> done"
