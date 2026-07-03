#!/usr/bin/env bash
# Build Xios camera/microphone support inside the Procursus/cctools container.
set -euo pipefail

SRC=/work/media
OUT=/out
BUILD=/tmp/xios-media-build
PREFIX=/var/jb/usr
ARCH=iphoneos-arm64
VERSION=0.1.0

CC="${CC:-aarch64-apple-darwin-clang}"
SYSROOT="${SYSROOT:-/root/cctools/SDK/iPhoneOS.sdk}"
CFLAGS="-isysroot $SYSROOT -miphoneos-version-min=16.0 -arch arm64 -O2 -Wall -Wextra -I$SRC"
LDFLAGS="-isysroot $SYSROOT -miphoneos-version-min=16.0 -arch arm64"

rm -rf "$BUILD"
mkdir -p "$BUILD" "$OUT"

echo "==> compile xios-mediad"
$CC $CFLAGS "$SRC/xios-mediad.m" -o "$BUILD/xios-mediad" \
    $LDFLAGS -framework AVFoundation -framework AudioToolbox \
    -framework CoreMedia -framework CoreVideo -framework CoreFoundation \
    -framework Foundation -lpthread

echo "==> compile xios-camera-dump"
$CC $CFLAGS "$SRC/xios-camera-dump.c" -o "$BUILD/xios-camera-dump" $LDFLAGS

echo "==> compile xios-mic-dump"
$CC $CFLAGS "$SRC/xios-mic-dump.c" -o "$BUILD/xios-mic-dump" $LDFLAGS

if command -v ldid >/dev/null 2>&1; then
    ldid -S"$SRC/media.xml" "$BUILD/xios-mediad" || ldid -S "$BUILD/xios-mediad"
    ldid -S"$SRC/media.xml" "$BUILD/xios-camera-dump" || ldid -S "$BUILD/xios-camera-dump"
    ldid -S"$SRC/media.xml" "$BUILD/xios-mic-dump" || ldid -S "$BUILD/xios-mic-dump"
fi

pkg_root() {
    local name="$1"
    rm -rf "$BUILD/$name"
    mkdir -p "$BUILD/$name/DEBIAN"
}

write_control() {
    local name="$1" package="$2" description="$3"
    cat > "$BUILD/$name/DEBIAN/control" <<EOF
Package: $package
Version: $VERSION
Architecture: $ARCH
Maintainer: Xios <root@localhost>
Section: utils
Priority: optional
Description: $description
EOF
}

echo "==> package xios-media-server"
pkg_root server
write_control server xios-media-server "Camera and microphone bridge daemon for Xios desktop sessions"
mkdir -p "$BUILD/server$PREFIX/bin" "$BUILD/server$PREFIX/share/xios" "$BUILD/server/var/jb/etc/profile.d"
install -m0755 "$BUILD/xios-mediad" "$BUILD/server$PREFIX/bin/xios-mediad"
install -m0755 "$BUILD/xios-camera-dump" "$BUILD/server$PREFIX/bin/xios-camera-dump"
install -m0755 "$BUILD/xios-mic-dump" "$BUILD/server$PREFIX/bin/xios-mic-dump"
install -m0644 "$SRC/xios_media_protocol.h" "$BUILD/server$PREFIX/share/xios/xios_media_protocol.h"
install -m0755 "$SRC/xios-media-session.sh" "$BUILD/server/var/jb/etc/profile.d/xios-media.sh"
dpkg-deb --root-owner-group -b "$BUILD/server" "$OUT/xios-media-server_${VERSION}_${ARCH}.deb"

echo "==> media artifacts:"
ls -l "$OUT"/xios-media-server_*
