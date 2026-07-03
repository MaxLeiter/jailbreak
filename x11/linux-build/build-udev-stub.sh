#!/usr/bin/env bash
# Build the libudev STUB (see udev-stub/) for rootless iOS and install it into the Procursus
# volume sysroot so gnome-bluetooth resolves `dependency('libudev')`. Only the hwdb entry points
# lib/pin.c uses are implemented (returning empty). Stages a runtime deb tree into /out.
#
#   docker run --rm --platform linux/arm64 -v procursus-vol-shell:/work/Procursus \
#     -v "$PWD/udev-stub:/work/udev-stub:ro" \
#     -v "$PWD/build-udev-stub.sh:/work/build-udev-stub.sh:ro" -v "$PWD/out:/out" \
#     --entrypoint bash procursus-xbuild:bookworm-arm64 /work/build-udev-stub.sh
set -euo pipefail
umask 022
PROC=/work/Procursus
SRC=/work/udev-stub
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

CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=$TARGET_MIN_IOS -O2 -Wall -Wextra"
DYLIB=libudev.1.dylib
echo "==> compiling $DYLIB"
# shellcheck disable=SC2086
$CC $CFLAGS -dynamiclib -fvisibility=default \
    -install_name @rpath/$DYLIB -compatibility_version 1.0.0 -current_version 1.7.0 \
    -I"$SRC" "$SRC/udev-stub.c" -Wl,-rpath,"$TARGET_INSTALL_PREFIX/lib" -o "/tmp/$DYLIB"
[ -n "$LDID" ] && "$LDID" -S "/tmp/$DYLIB"
file "/tmp/$DYLIB" | sed 's/^/   /'

echo "==> installing into volume sysroot ($SYSROOT)"
install -m 0755 "/tmp/$DYLIB" "$SYSROOT/lib/$DYLIB"
ln -sf "$DYLIB" "$SYSROOT/lib/libudev.dylib"     # unversioned dev symlink for -ludev
install -m 0644 "$SRC/libudev.h" "$SYSROOT/include/libudev.h"
cat > "$SYSROOT/lib/pkgconfig/libudev.pc" <<PC
prefix=$TARGET_INSTALL_PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libudev
Description: libudev stub for iOS (no udev; hwdb returns empty)
Version: 251
Libs: -L\${libdir} -ludev
Cflags: -I\${includedir}
PC
echo "   installed libudev.pc + libudev.h + $DYLIB (+ symlink)"

echo "==> staging runtime tree -> $OUT/udev-stub-tree"
DEST="$OUT/udev-stub-tree$TARGET_PACKAGE_PATH_PREFIX$TARGET_SUBPREFIX/lib"
mkdir -p "$DEST"
install -m 0755 "/tmp/$DYLIB" "$DEST/$DYLIB"
ln -sf "$DYLIB" "$DEST/libudev.dylib"
echo "==> done"
