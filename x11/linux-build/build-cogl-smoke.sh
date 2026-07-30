#!/usr/bin/env bash
# Cross-builds x11/wayland/iosc-cogl-smoke.c (Cogl-on-ANGLE-ES3 de-risk) OFF-DEVICE: it needs
# cogl's PRIVATE winsys headers, only present in the mutter source tree (though the symbols are
# exported from libmutter-cogl), then gets retargeted onto installed device dylib paths.
#
#   docker run --rm --platform linux/arm64 -v procursus-vol-gtk:/work/Procursus \
#     -v "$PWD/../wayland:/src:ro" -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 -c 'bash /src/../linux-build/build-cogl-smoke.sh'
# (or just run the body below in the container). Output: out/iosc-cogl-smoke.
set -euo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"

M=$XIOS_BUILD_WORK/mutter
B=$M/build
SYS=$XIOS_SYSROOT/usr
CC=/work/Procursus/build_tools/cc-nounused
INT=aarch64-apple-darwin-install_name_tool
SRC=${1:-/src/iosc-cogl-smoke.c}
OUT=${2:-/out/iosc-cogl-smoke}

INC="-I$B -I$M -I$M/cogl -I$B/cogl -I$M/cogl/cogl -I$B/cogl/cogl -I$M/mtk -I$B/mtk -I$M/mtk/mtk -I$B/mtk/mtk \
     -I$SYS/include/glib-2.0 -I$SYS/lib/glib-2.0/include -I$SYS/include \
     -I$SYS/include/graphene-1.0 -I$SYS/lib/graphene-1.0/include -I$SYS/include/pixman-1"

echo "==> compile + link (iOS arm64, against build-tree libmutter-cogl-14)"
$CC -DCOGL_COMPILATION -Wno-nullability-completeness -Wno-expansion-to-defined \
    "$SRC" -o "$OUT" $INC \
    "$B/cogl/cogl/libmutter-cogl-14.0.dylib" -L"$SYS/lib" -lEGL -lGLESv2 -lglib-2.0 -lgobject-2.0

echo "==> retarget @rpath deps onto the INSTALLED device paths (libmutter-14-0 deb + ANGLE)"
$INT -change @rpath/libmutter-cogl-14.0.dylib $XIOS_PREFIX/usr/lib/mutter-14/libmutter-cogl-14.0.dylib "$OUT"
$INT -change @rpath/libGLESv2.2.dylib         $XIOS_PREFIX/lib/angle/libGLESv2.2.dylib                "$OUT"
$INT -change @rpath/libglib-2.0.0.dylib       $XIOS_PREFIX/usr/lib/libglib-2.0.0.dylib                "$OUT"
$INT -change @rpath/libgobject-2.0.0.dylib    $XIOS_PREFIX/usr/lib/libgobject-2.0.0.dylib             "$OUT"
$INT -add_rpath $XIOS_PREFIX/usr/lib/mutter-14 "$OUT" 2>/dev/null || true
$INT -add_rpath $XIOS_PREFIX/usr/lib           "$OUT" 2>/dev/null || true
$INT -add_rpath $XIOS_PREFIX/lib/angle         "$OUT" 2>/dev/null || true
ldid -S "$OUT"

echo "==> done: $OUT"
aarch64-apple-darwin-otool -L "$OUT" 2>/dev/null | sed -n '2,12p'
