#!/usr/bin/env bash
# Build the libpwquality STUB (see pwquality-stub/pwquality-stub.c) for rootless iOS and install
# it into the Procursus volume sysroot so gnome-control-center resolves `dependency('pwquality')`.
# Avoids cross-building cracklib. Also stages a runtime deb tree into /out.
#
#   docker run --rm --platform linux/arm64 \
#     -v procursus-vol-shell:/work/Procursus \
#     -v "$PWD/pwquality-stub:/work/pwquality-stub:ro" \
#     -v "$PWD/build-pwquality-stub.sh:/work/build-pwquality-stub.sh:ro" -v "$PWD/out:/out" \
#     --entrypoint bash procursus-xbuild:bookworm-arm64 /work/build-pwquality-stub.sh
set -euo pipefail
umask 022
PROC=/work/Procursus
SRC=/work/pwquality-stub
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
DYLIB=libpwquality.1.dylib
echo "==> compiling $DYLIB"
# shellcheck disable=SC2086
$CC $CFLAGS -dynamiclib -fvisibility=default \
    -install_name @rpath/$DYLIB -compatibility_version 1.0.0 -current_version 1.4.5 \
    -I"$SRC" "$SRC/pwquality-stub.c" -Wl,-rpath,"$TARGET_INSTALL_PREFIX/lib" -o "/tmp/$DYLIB"
[ -n "$LDID" ] && "$LDID" -S "/tmp/$DYLIB"
file "/tmp/$DYLIB" | sed 's/^/   /'

echo "==> installing into volume sysroot ($SYSROOT)"
install -m 0755 "/tmp/$DYLIB" "$SYSROOT/lib/$DYLIB"
ln -sf "$DYLIB" "$SYSROOT/lib/libpwquality.dylib"   # unversioned dev symlink for -lpwquality
install -m 0644 "$SRC/pwquality.h" "$SYSROOT/include/pwquality.h"
cat > "$SYSROOT/lib/pkgconfig/pwquality.pc" <<PC
prefix=$TARGET_INSTALL_PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: pwquality
Description: libpwquality stub for iOS (local scoring/generation; no cracklib)
Version: 1.4.5
Libs: -L\${libdir} -lpwquality
Cflags: -I\${includedir}
PC
echo "   installed pwquality.pc + pwquality.h + $DYLIB (+ symlink)"

echo "==> staging runtime tree -> $OUT/pwquality-stub-tree"
DEST="$OUT/pwquality-stub-tree$TARGET_PACKAGE_PATH_PREFIX$TARGET_SUBPREFIX/lib"
mkdir -p "$DEST"
install -m 0755 "/tmp/$DYLIB" "$DEST/$DYLIB"
ln -sf "$DYLIB" "$DEST/libpwquality.dylib"
echo "==> done"
