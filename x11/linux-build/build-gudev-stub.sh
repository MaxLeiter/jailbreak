#!/usr/bin/env bash
# Build the libgudev-1.0 STUB (see gudev-stub/gudev-stub.c) for rootless iOS and install it
# into the Procursus volume sysroot so the gnome-control-center / gnome-bluetooth cross builds
# resolve `dependency('gudev-1.0')`. Also stages a runtime deb tree into /out.
#
#   docker run --rm --platform linux/arm64 \
#     -v procursus-vol-shell:/work/Procursus \
#     -v "$PWD/gudev-stub:/work/gudev-stub:ro" \
#     -v "$PWD/build-gudev-stub.sh:/work/build-gudev-stub.sh:ro" -v "$PWD/out:/out" \
#     --entrypoint bash procursus-xbuild:bookworm-arm64 /work/build-gudev-stub.sh
set -euo pipefail
umask 022
PROC=/work/Procursus
SRC=/work/gudev-stub
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
[ -d "$SYSROOT/include/glib-2.0" ] || { echo "!! glib not in sysroot: $SYSROOT"; exit 1; }

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

DYLIB=libgudev-1.0.0.dylib
echo "==> compiling $DYLIB"
# -I$SRC so <gudev/gudev.h> resolves to our shipped headers; install_name @rpath so the
# device dyld finds it via the standard rpath (matches every other lib in the stack).
# shellcheck disable=SC2086
$CC $CFLAGS -dynamiclib -fvisibility=default \
    -install_name @rpath/$DYLIB -compatibility_version 1.0.0 -current_version 1.3.0 \
    -I"$SRC" "$SRC/gudev-stub.c" $GLIB_FLAGS -L"$SYSROOT/lib" \
    -Wl,-rpath,"$TARGET_INSTALL_PREFIX/lib" -o "/tmp/$DYLIB"
[ -n "$LDID" ] && "$LDID" -S "/tmp/$DYLIB"
file "/tmp/$DYLIB" | sed 's/^/   /'

echo "==> installing into volume sysroot ($SYSROOT)"
install -m 0755 "/tmp/$DYLIB" "$SYSROOT/lib/$DYLIB"
ln -sf "$DYLIB" "$SYSROOT/lib/libgudev-1.0.dylib"     # unversioned dev symlink for -lgudev-1.0
mkdir -p "$SYSROOT/include/gudev-1.0/gudev"
cp -v "$SRC/gudev/"*.h "$SYSROOT/include/gudev-1.0/gudev/"
cat > "$SYSROOT/lib/pkgconfig/gudev-1.0.pc" <<PC
prefix=$TARGET_INSTALL_PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: gudev-1.0
Description: GUdev stub for iOS (no udev; enumerates nothing)
Version: 238
Requires: glib-2.0 gobject-2.0
Libs: -L\${libdir} -lgudev-1.0
Cflags: -I\${includedir}/gudev-1.0
PC
echo "   installed gudev-1.0.pc + headers + $DYLIB (+ symlink)"

# stage a runtime deb tree into /out (host-side build.sh runs xmkdeb over it)
echo "==> staging runtime tree -> $OUT/gudev-stub-tree"
DEST="$OUT/gudev-stub-tree$TARGET_PACKAGE_PATH_PREFIX$TARGET_SUBPREFIX/lib"
mkdir -p "$DEST"
install -m 0755 "/tmp/$DYLIB" "$DEST/$DYLIB"
ln -sf "$DYLIB" "$DEST/libgudev-1.0.dylib"
echo "==> done"
