#!/usr/bin/env bash
# Cross-compile test/hello-gtk4-persist.c against the staged GTK4 stack.
#   docker run --rm -v procursus-vol-gtk:/work/Procursus \
#     -v "$PWD/test:/work/test:ro" -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 /work/test/build-hello-gtk4-persist.sh
set -euo pipefail

export BUILD_BASE=/work/Procursus/build_base/iphoneos-arm64-rootless/1900
export MEMO_PREFIX=/var/jb
export MEMO_SUB_PREFIX=/usr
export MEMO_ALT_PREFIX=
SYSROOT=/root/cctools/SDK/iPhoneOS.sdk
PKGC=/work/Procursus/build_tools/cross-pkg-config

CFLAGS_PKG=$("$PKGC" --cflags gtk4)
LIBS_PKG=$("$PKGC" --libs gtk4)

aarch64-apple-darwin-clang /work/test/hello-gtk4-persist.c -o /out/hello-gtk4-persist \
    -Os -arch arm64 -isysroot "$SYSROOT" -miphoneos-version-min=16.0 \
    -isystem "$BUILD_BASE/var/jb/usr/include" \
    $CFLAGS_PKG $LIBS_PKG \
    -Wl,-rpath,/var/jb/usr/lib -liosexec

# Match gtkfix's libintl coherence fix: GTK is relinked off proxy-libintl onto the
# renamed libgtkintl (the proxy's g_libintl_* symbols), so point this binary there too.
aarch64-apple-darwin-install_name_tool -change @rpath/libintl.dylib @rpath/libgtkintl.dylib /out/hello-gtk4-persist 2>/dev/null || true

echo "== built /out/hello-gtk4-persist =="
file /out/hello-gtk4-persist
echo "== intl + gtk linkage =="
aarch64-apple-darwin-otool -L /out/hello-gtk4-persist | grep -iE "gtk-4|intl" | head
