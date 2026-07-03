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
SYSROOT_ROOT="$PROC/build_base/iphoneos-arm64-rootless/1900"
SYSROOT="$SYSROOT_ROOT/var/jb/usr"

CC=""
for cand in aarch64-apple-darwin-clang arm64-apple-darwin-clang; do
  command -v "$cand" >/dev/null 2>&1 && { CC="$cand"; break; }
done
[ -n "$CC" ] || { echo "!! cross clang not found"; exit 1; }
SDK="$(dirname "$(command -v "$CC")")/../SDK/iPhoneOS.sdk"
LDID="$(command -v ldid || true)"

export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig:$SYSROOT/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT_ROOT"
CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0 -O2 -Wall -Wextra -Wno-unused-parameter"
GLIB_FLAGS="$(pkg-config --cflags --libs gio-2.0 gobject-2.0 glib-2.0)"

DYLIB=libgsound.0.dylib
echo "==> compiling $DYLIB"
# shellcheck disable=SC2086
$CC $CFLAGS -dynamiclib -fvisibility=default \
    -install_name @rpath/$DYLIB -compatibility_version 1.0.0 -current_version 1.0.3 \
    -I"$SRC" "$SRC/gsound-stub.c" $GLIB_FLAGS -L"$SYSROOT/lib" \
    -Wl,-rpath,/var/jb/usr/lib -o "/tmp/$DYLIB"
[ -n "$LDID" ] && "$LDID" -S "/tmp/$DYLIB"
file "/tmp/$DYLIB" | sed 's/^/   /'

echo "==> installing into volume sysroot ($SYSROOT)"
install -m 0755 "/tmp/$DYLIB" "$SYSROOT/lib/$DYLIB"
ln -sf "$DYLIB" "$SYSROOT/lib/libgsound.dylib"    # unversioned dev symlink for -lgsound
# Upstream install_headers() puts all three at $includedir root; consumers use <gsound.h>,
# which #includes "gsound-context.h"/"gsound-attr.h" from the same dir.
cp -v "$SRC/gsound.h" "$SRC/gsound-context.h" "$SRC/gsound-attr.h" "$SYSROOT/include/"
cat > "$SYSROOT/lib/pkgconfig/gsound.pc" <<PC
prefix=/var/jb/usr
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
DEST="$OUT/gsound-stub-tree/var/jb/usr/lib"
mkdir -p "$DEST"
install -m 0755 "/tmp/$DYLIB" "$DEST/$DYLIB"
ln -sf "$DYLIB" "$DEST/libgsound.dylib"
echo "==> done"
