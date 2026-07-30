#!/usr/bin/env bash
# Build a tiny Qt Wayland/OpenGL smoke-test package against the local Qt debs.
set -euo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"

ROOT=/work/Procursus
TARGET=$XIOS_MEMO_TARGET
CFVER=1900
BUILD_BASE="$ROOT/build_base/$TARGET/$CFVER"
BUILD_WORK="$ROOT/build_work/$TARGET/$CFVER/qt-wayland-gl-smoke"
BUILD_DIST="$ROOT/build_dist/$TARGET/$CFVER/work/qt-wayland-gl-smoke"
OUT="${OUT:-/out}"
VERSION="${DEB_QT_WAYLAND_GL_SMOKE_V:-0.1.0}"
ARCH=iphoneos-arm64
PREFIX=$XIOS_PREFIX
SYSROOT="$BUILD_BASE$PREFIX/usr"
SDK=/root/cctools/SDK/iPhoneOS.sdk
CXX=/root/cctools/bin/aarch64-apple-darwin-clang++
OTOOL=/root/cctools/bin/aarch64-apple-darwin-otool
STRIP=/root/cctools/bin/aarch64-apple-darwin-strip
INSTALL_NAME_TOOL=/root/cctools/bin/aarch64-apple-darwin-install_name_tool
LDID=/root/cctools/bin/ldid

stage_deb() {
  local pattern="$1"
  local deb
  deb="$(find "$OUT" -maxdepth 1 -name "$pattern" | sort -V | tail -n 1)"
  if [ -z "$deb" ]; then
    echo "ERROR: missing dependency deb matching $pattern in $OUT" >&2
    exit 1
  fi
  echo "==> staging $(basename "$deb")"
  dpkg-deb -x "$deb" "$BUILD_BASE"
}

mkdir -p "$BUILD_BASE" "$BUILD_WORK" "$BUILD_DIST" "$OUT"

stage_deb 'qt6-base_6.6.3-3_iphoneos-arm64.deb'
stage_deb 'qt6-base-dev_6.6.3-3_iphoneos-arm64.deb'
stage_deb 'qt6-wayland_6.6.3-*_iphoneos-arm64.deb'
stage_deb 'qt6-wayland-dev_6.6.3-*_iphoneos-arm64.deb'
stage_deb 'angle_*+es3-[0-9]*_iphoneos-arm64.deb'
stage_deb 'libwayland0_1.23.1_iphoneos-arm64.deb'
stage_deb 'libwayland-dev_1.23.1_iphoneos-arm64.deb'

cp /work/qt-wayland-gl-smoke/main.cpp "$BUILD_WORK/main.cpp"

COMMON_FLAGS=(
  -Os
  -arch arm64
  -isysroot "$SDK"
  -miphoneos-version-min=16.0
  -std=c++17
  -stdlib=libc++
  -D_DARWIN_C_SOURCE
  -DQT_NO_DEBUG
  -include "$ROOT/build_tools/qt-ios-iosexec-fixup.h"
  -I"$SYSROOT/include"
  -I"$SYSROOT/include/QtCore"
  -I"$SYSROOT/include/QtGui"
  -isystem "$SDK/usr/include/c++/v1"
  -isystem "$SYSROOT/include/c++/v1"
  -F"$BUILD_BASE$PREFIX/System/Library/Frameworks"
  -F"$BUILD_BASE$PREFIX/Library/Frameworks"
)

LINK_FLAGS=(
  -L"$BUILD_BASE$PREFIX/lib/angle"
  -L"$SYSROOT/lib"
  -Wl,-rpath,$XIOS_PREFIX/usr/lib
  -Wl,-rpath,$XIOS_PREFIX/lib/angle
  -Wl,-not_for_dyld_shared_cache
  -stdlib=libc++
  -liosexec
  -lQt6Gui
  -lQt6Core
  -lEGL
  -lGLESv2
  -framework UIKit
  -framework CoreServices
  -framework MobileCoreServices
  -framework Security
  -framework Foundation
  -framework CoreFoundation
  -framework CoreGraphics
  -framework Metal
  -lobjc
)

echo "==> compiling qt-wayland-gl-smoke"
"$CXX" "${COMMON_FLAGS[@]}" "$BUILD_WORK/main.cpp" "${LINK_FLAGS[@]}" \
  -o "$BUILD_WORK/qt-wayland-gl-smoke"

"$INSTALL_NAME_TOOL" -change @rpath/libGLESv2.2.dylib $XIOS_PREFIX/lib/angle/libGLESv2.dylib \
  "$BUILD_WORK/qt-wayland-gl-smoke" 2>/dev/null || true
"$INSTALL_NAME_TOOL" -change @rpath/libGLESv2.dylib $XIOS_PREFIX/lib/angle/libGLESv2.dylib \
  "$BUILD_WORK/qt-wayland-gl-smoke" 2>/dev/null || true

"$STRIP" -x "$BUILD_WORK/qt-wayland-gl-smoke" || true
"$LDID" -S/work/build_info/qt-wayland-gl-smoke-ent.xml \
  "$BUILD_WORK/qt-wayland-gl-smoke"

echo "==> linked libraries"
"$OTOOL" -L "$BUILD_WORK/qt-wayland-gl-smoke"

rm -rf "$BUILD_DIST"
mkdir -p "$BUILD_DIST$PREFIX/usr/bin" \
  "$BUILD_DIST$PREFIX/usr/share/qt-wayland-gl-smoke" \
  "$BUILD_DIST/DEBIAN"
install -m 0755 "$BUILD_WORK/qt-wayland-gl-smoke" \
  "$BUILD_DIST$PREFIX/usr/bin/qt-wayland-gl-smoke"
install -m 0644 /work/build_info/qt-wayland-gl-smoke-ent.xml \
  "$BUILD_DIST$PREFIX/usr/share/qt-wayland-gl-smoke/qt-wayland-gl-smoke-ent.xml"

sed \
  -e "s/@DEB_QT_WAYLAND_GL_SMOKE_V@/$VERSION/g" \
  -e "s/@DEB_ARCH@/$ARCH/g" \
  /work/build_info/qt-wayland-gl-smoke.control > "$BUILD_DIST/DEBIAN/control"

cat > "$BUILD_DIST/DEBIAN/postinst" <<POSTINST
#!/bin/sh
set -e
PREFIX=$XIOS_PREFIX
POSTINST
cat >> "$BUILD_DIST/DEBIAN/postinst" <<'POSTINST'

if [ "$1" = configure ] && [ -x $PREFIX/usr/bin/ldid ]; then
  $PREFIX/usr/bin/ldid \
    -S$PREFIX/usr/share/qt-wayland-gl-smoke/qt-wayland-gl-smoke-ent.xml \
    $PREFIX/usr/bin/qt-wayland-gl-smoke
fi

exit 0
POSTINST

cd "$BUILD_DIST"
find . -type f ! -path './DEBIAN/*' -printf '"%P" ' | xargs md5sum > DEBIAN/md5sums
chmod 0755 DEBIAN/*
SIZE="$(du -sk "$BUILD_DIST" | cut -f1)"
printf 'Installed-Size: %s\n' "$SIZE" >> DEBIAN/control

DEB="$OUT/qt-wayland-gl-smoke_${VERSION}_${ARCH}.deb"
fakeroot dpkg-deb -Zzstd -b "$BUILD_DIST" "$DEB"
echo "==> built $DEB"
