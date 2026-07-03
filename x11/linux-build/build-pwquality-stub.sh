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
SYSROOT_ROOT="$PROC/build_base/iphoneos-arm64-rootless/1900"
SYSROOT="$SYSROOT_ROOT/var/jb/usr"

CC=""
for cand in aarch64-apple-darwin-clang arm64-apple-darwin-clang; do
  command -v "$cand" >/dev/null 2>&1 && { CC="$cand"; break; }
done
[ -n "$CC" ] || { echo "!! cross clang not found"; exit 1; }
SDK="$(dirname "$(command -v "$CC")")/../SDK/iPhoneOS.sdk"
LDID="$(command -v ldid || true)"

CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0 -O2 -Wall -Wextra"
DYLIB=libpwquality.1.dylib
echo "==> compiling $DYLIB"
# shellcheck disable=SC2086
$CC $CFLAGS -dynamiclib -fvisibility=default \
    -install_name @rpath/$DYLIB -compatibility_version 1.0.0 -current_version 1.4.5 \
    -I"$SRC" "$SRC/pwquality-stub.c" -Wl,-rpath,/var/jb/usr/lib -o "/tmp/$DYLIB"
[ -n "$LDID" ] && "$LDID" -S "/tmp/$DYLIB"
file "/tmp/$DYLIB" | sed 's/^/   /'

echo "==> installing into volume sysroot ($SYSROOT)"
install -m 0755 "/tmp/$DYLIB" "$SYSROOT/lib/$DYLIB"
ln -sf "$DYLIB" "$SYSROOT/lib/libpwquality.dylib"   # unversioned dev symlink for -lpwquality
install -m 0644 "$SRC/pwquality.h" "$SYSROOT/include/pwquality.h"
cat > "$SYSROOT/lib/pkgconfig/pwquality.pc" <<PC
prefix=/var/jb/usr
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
DEST="$OUT/pwquality-stub-tree/var/jb/usr/lib"
mkdir -p "$DEST"
install -m 0755 "/tmp/$DYLIB" "$DEST/$DYLIB"
ln -sf "$DYLIB" "$DEST/libpwquality.dylib"
echo "==> done"
