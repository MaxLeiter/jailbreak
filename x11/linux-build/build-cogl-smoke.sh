#!/usr/bin/env bash
# build-cogl-smoke.sh — cross-build x11/wayland/iosc-cogl-smoke.c (the Cogl-on-ANGLE-ES3
# de-risk) into a device-ready iOS arm64 binary, OFF-DEVICE, against the mutter source tree
# + the already-built libmutter-cogl-14 in the procursus-vol-gtk volume.
#
# Why off-device works: the smoke test needs cogl's PRIVATE winsys headers (only in the
# mutter source tree, not in libmutter-14-dev) and links the private winsys symbols
# (_cogl_winsys_egl_get_vtable / _renderer_connect_common / _make_current), which ARE
# exported from libmutter-cogl (mutter's own libmutter links them cross-dylib). The result
# is retargeted onto the INSTALLED device dylib paths, so it runs against the libmutter-14-0
# deb + ANGLE WITHOUT an on-device mutter build — decoupling the Cogl de-risk from the heavy
# typelib build.
#
#   docker run --rm --platform linux/arm64 -v procursus-vol-gtk:/work/Procursus \
#     -v "$PWD/../wayland:/src:ro" -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 -c 'bash /src/../linux-build/build-cogl-smoke.sh'
# (or just run the body below in the container). Output: out/iosc-cogl-smoke.
set -euo pipefail

M=/work/Procursus/build_work/iphoneos-arm64-rootless/1900/mutter
B=$M/build
SYS=/work/Procursus/build_base/iphoneos-arm64-rootless/1900/var/jb/usr
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
$INT -change @rpath/libmutter-cogl-14.0.dylib /var/jb/usr/lib/mutter-14/libmutter-cogl-14.0.dylib "$OUT"
$INT -change @rpath/libGLESv2.2.dylib         /var/jb/lib/angle/libGLESv2.2.dylib                "$OUT"
$INT -change @rpath/libglib-2.0.0.dylib       /var/jb/usr/lib/libglib-2.0.0.dylib                "$OUT"
$INT -change @rpath/libgobject-2.0.0.dylib    /var/jb/usr/lib/libgobject-2.0.0.dylib             "$OUT"
$INT -add_rpath /var/jb/usr/lib/mutter-14 "$OUT" 2>/dev/null || true
$INT -add_rpath /var/jb/usr/lib           "$OUT" 2>/dev/null || true
$INT -add_rpath /var/jb/lib/angle         "$OUT" 2>/dev/null || true
ldid -S "$OUT"

echo "==> done: $OUT"
aarch64-apple-darwin-otool -L "$OUT" 2>/dev/null | sed -n '2,12p'
