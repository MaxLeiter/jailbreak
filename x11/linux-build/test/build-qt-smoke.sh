#!/usr/bin/env bash
# Cross-compile test/qt-smoke.cpp against the staged qtbase in the build container.
#   docker run --rm --platform linux/arm64 -v procursus-vol-qt:/work/Procursus \
#     -v "$PWD/test:/work/test:ro" -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 /work/test/build-qt-smoke.sh
# Produces /out/qt-smoke (fakesign with ldid on device before running).
set -euo pipefail

BUILD_BASE=/work/Procursus/build_base/iphoneos-arm64-rootless/1900
SYSROOT=/root/cctools/SDK/iPhoneOS.sdk
INC=$BUILD_BASE/var/jb/usr/include
LIB=$BUILD_BASE/var/jb/usr/lib

aarch64-apple-darwin-clang++ /work/test/qt-smoke.cpp -o /out/qt-smoke \
    -std=c++17 -Os -arch arm64 -isysroot "$SYSROOT" -miphoneos-version-min=16.0 \
    -stdlib=libc++ -isystem "$SYSROOT/usr/include/c++/v1" \
    -isystem "$INC" -isystem "$INC/QtCore" -isystem "$INC/QtGui" \
    -L"$LIB" -lQt6Core -lQt6Gui \
    -Wl,-rpath,/var/jb/usr/lib

echo "== built /out/qt-smoke =="
file /out/qt-smoke 2>/dev/null || true
echo "== linked dylibs =="
aarch64-apple-darwin-otool -L /out/qt-smoke
