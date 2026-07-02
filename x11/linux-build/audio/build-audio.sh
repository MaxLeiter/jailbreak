#!/usr/bin/env bash
# Build Xios audio support inside the Procursus/cctools container.
set -euo pipefail

SRC=/work/audio
OUT=/out
BUILD=/tmp/xios-audio-build
PREFIX=/var/jb/usr
ARCH=iphoneos-arm64
VERSION=0.1.0

CC="${CC:-aarch64-apple-darwin-clang}"
SYSROOT="${SYSROOT:-/root/cctools/SDK/iPhoneOS.sdk}"
CFLAGS="-isysroot $SYSROOT -miphoneos-version-min=16.0 -arch arm64 -O2 -Wall -Wextra -I$SRC"
LDFLAGS="-isysroot $SYSROOT -miphoneos-version-min=16.0 -arch arm64"

rm -rf "$BUILD"
mkdir -p "$BUILD" "$OUT"

echo "==> compile xios-audiod"
$CC $CFLAGS "$SRC/xios-audiod.c" "$SRC/xios_audio_session.m" -o "$BUILD/xios-audiod" \
    $LDFLAGS -framework AudioToolbox -framework CoreFoundation \
    -framework AVFoundation -framework Foundation -lpthread

echo "==> compile xios-audio-play"
$CC $CFLAGS "$SRC/xios_audio_client.c" "$SRC/xios-audio-play.c" \
    -o "$BUILD/xios-audio-play" $LDFLAGS

if command -v ldid >/dev/null 2>&1; then
    ldid -S"$SRC/audio.xml" "$BUILD/xios-audiod" || ldid -S "$BUILD/xios-audiod"
    ldid -S"$SRC/audio.xml" "$BUILD/xios-audio-play" || ldid -S "$BUILD/xios-audio-play"
fi

pkg_root() {
    local name="$1"
    rm -rf "$BUILD/$name"
    mkdir -p "$BUILD/$name/DEBIAN"
}

write_control() {
    local name="$1" package="$2" depends="$3" description="$4"
    cat > "$BUILD/$name/DEBIAN/control" <<EOF
Package: $package
Version: $VERSION
Architecture: $ARCH
Maintainer: Xios <root@localhost>
Section: sound
Priority: optional
Description: $description
EOF
    if [ -n "$depends" ]; then
        sed -i "/^Maintainer:/a Depends: $depends" "$BUILD/$name/DEBIAN/control"
    fi
}

echo "==> package xios-audio-server"
pkg_root server
write_control server xios-audio-server "" "CoreAudio bridge daemon for Xios desktop audio"
mkdir -p "$BUILD/server$PREFIX/bin" "$BUILD/server$PREFIX/share/xios" "$BUILD/server/var/jb/etc/profile.d"
install -m0755 "$BUILD/xios-audiod" "$BUILD/server$PREFIX/bin/xios-audiod"
install -m0755 "$BUILD/xios-audio-play" "$BUILD/server$PREFIX/bin/xios-audio-play"
install -m0644 "$SRC/xios_audio_protocol.h" "$BUILD/server$PREFIX/share/xios/xios_audio_protocol.h"
install -m0755 "$SRC/xios-audio-session.sh" "$BUILD/server/var/jb/etc/profile.d/xios-audio.sh"
dpkg-deb --root-owner-group -b "$BUILD/server" "$OUT/xios-audio-server_${VERSION}_${ARCH}.deb"

echo "==> audio artifacts:"
ls -l "$OUT"/xios-audio-server_*
