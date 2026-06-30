#!/usr/bin/env bash
# Cross-compile test/hello-gtk.c against the staged GTK3 stack in the Procursus
# build container. Run via:
#   docker run --rm -v procursus-vol-gtk:/work/Procursus \
#     -v "$PWD/test:/work/test:ro" -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 bash /work/test/build-hello-gtk.sh
# Produces /out/hello-gtk (ad-hoc sign before running on device).
set -euo pipefail

export BUILD_BASE=/work/Procursus/build_base/iphoneos-arm64-rootless/1900
export MEMO_PREFIX=/var/jb
export MEMO_SUB_PREFIX=/usr
export MEMO_ALT_PREFIX=
SYSROOT=/root/cctools/SDK/iPhoneOS.sdk
PKGC=/work/Procursus/build_tools/cross-pkg-config

CFLAGS_PKG=$("$PKGC" --cflags gtk+-3.0)
LIBS_PKG=$("$PKGC" --libs gtk+-3.0)

aarch64-apple-darwin-clang /work/test/hello-gtk.c -o /out/hello-gtk \
    -Os -arch arm64 -isysroot "$SYSROOT" -miphoneos-version-min=16.0 \
    -isystem "$BUILD_BASE/var/jb/usr/include" \
    $CFLAGS_PKG $LIBS_PKG \
    -Wl,-rpath,/var/jb/usr/lib -liosexec

# Match the shipped libs: link onto the system gettext libintl.8 (BUILD_BASE's
# libintl.dylib symlink may have been clobbered by gtk's bundled proxy-libintl).
aarch64-apple-darwin-install_name_tool -change @rpath/libintl.dylib @rpath/libintl.8.dylib /out/hello-gtk 2>/dev/null || true

echo "== built /out/hello-gtk =="
file /out/hello-gtk
echo "== linked dylibs =="
aarch64-apple-darwin-otool -L /out/hello-gtk | grep -iE "gtk|gdk|pango|cairo|glib|intl" | head
