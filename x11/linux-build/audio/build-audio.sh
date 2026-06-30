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
CFLAGS="-isysroot $SYSROOT -miphoneos-version-min=16.0 -arch arm64 -O2 -Wall -Wextra -I$SRC -I$SRC/pulse"
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

echo "==> compile libpulse-simple shim"
$CC $CFLAGS -dynamiclib "$SRC/xios_audio_client.c" "$SRC/libpulse-simple-xios.c" \
    -o "$BUILD/libpulse-simple.0.dylib" $LDFLAGS \
    -install_name "$PREFIX/lib/libpulse-simple.0.dylib"

if command -v ldid >/dev/null 2>&1; then
    ldid -S"$SRC/audio.xml" "$BUILD/xios-audiod" || ldid -S "$BUILD/xios-audiod"
    ldid -S"$SRC/audio.xml" "$BUILD/xios-audio-play" || ldid -S "$BUILD/xios-audio-play"
    ldid -S"$SRC/audio.xml" "$BUILD/libpulse-simple.0.dylib" || ldid -S "$BUILD/libpulse-simple.0.dylib"
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

echo "==> package libpulse-simple-xios0"
pkg_root pulse0
write_control pulse0 libpulse-simple-xios0 "xios-audio-server" "libpulse-simple compatibility shim for Xios audio"
cat >> "$BUILD/pulse0/DEBIAN/control" <<'EOF'
Provides: libpulse-simple0
Conflicts: libpulse-simple0
Replaces: libpulse-simple0
EOF
mkdir -p "$BUILD/pulse0$PREFIX/lib"
install -m0755 "$BUILD/libpulse-simple.0.dylib" "$BUILD/pulse0$PREFIX/lib/libpulse-simple.0.dylib"
ln -s libpulse-simple.0.dylib "$BUILD/pulse0$PREFIX/lib/libpulse-simple.dylib"
dpkg-deb --root-owner-group -b "$BUILD/pulse0" "$OUT/libpulse-simple-xios0_${VERSION}_${ARCH}.deb"

echo "==> package libpulse-simple-xios-dev"
pkg_root pulsedev
write_control pulsedev libpulse-simple-xios-dev "libpulse-simple-xios0 (= $VERSION)" "development headers for the Xios libpulse-simple shim"
cat >> "$BUILD/pulsedev/DEBIAN/control" <<'EOF'
Provides: libpulse-simple-dev
Conflicts: libpulse-simple-dev
Replaces: libpulse-simple-dev
EOF
mkdir -p "$BUILD/pulsedev$PREFIX/include/pulse" "$BUILD/pulsedev$PREFIX/lib/pkgconfig"
install -m0644 "$SRC/pulse/"*.h "$BUILD/pulsedev$PREFIX/include/pulse/"
cat > "$BUILD/pulsedev$PREFIX/lib/pkgconfig/libpulse-simple.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: libpulse-simple-xios
Description: Xios libpulse-simple compatibility shim
Version: $VERSION
Libs: -L\${libdir} -lpulse-simple
Cflags: -I\${includedir}
EOF
dpkg-deb --root-owner-group -b "$BUILD/pulsedev" "$OUT/libpulse-simple-xios-dev_${VERSION}_${ARCH}.deb"

echo "==> audio artifacts:"
ls -l "$OUT"/xios-audio-server_* "$OUT"/libpulse-simple-xios*
