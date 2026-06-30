#!/usr/bin/env bash
# Cross-compile test/hello-gtk4.c against the staged GTK4 stack in the build container.
#   docker run --rm -v procursus-vol-gtk:/work/Procursus \
#     -v "$PWD/test:/work/test:ro" -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 /work/test/build-hello-gtk4.sh
# Produces /out/hello-gtk4 (ad-hoc sign before running on device).
set -euo pipefail

export BUILD_BASE=/work/Procursus/build_base/iphoneos-arm64-rootless/1900
export MEMO_PREFIX=/var/jb
export MEMO_SUB_PREFIX=/usr
export MEMO_ALT_PREFIX=
SYSROOT=/root/cctools/SDK/iPhoneOS.sdk
PKGC=/work/Procursus/build_tools/cross-pkg-config

CFLAGS_PKG=$("$PKGC" --cflags gtk4)
LIBS_PKG=$("$PKGC" --libs gtk4)

aarch64-apple-darwin-clang /work/test/hello-gtk4.c -o /out/hello-gtk4 \
    -Os -arch arm64 -isysroot "$SYSROOT" -miphoneos-version-min=16.0 \
    -isystem "$BUILD_BASE/var/jb/usr/include" \
    $CFLAGS_PKG $LIBS_PKG \
    -Wl,-rpath,/var/jb/usr/lib -liosexec

aarch64-apple-darwin-install_name_tool -change @rpath/libintl.dylib @rpath/libintl.8.dylib /out/hello-gtk4 2>/dev/null || true

echo "== built /out/hello-gtk4 =="
file /out/hello-gtk4
echo "== linked dylibs =="
aarch64-apple-darwin-otool -L /out/hello-gtk4 | grep -iE "gtk-4|graphene|epoxy|pango|cairo|glib|intl" | head
