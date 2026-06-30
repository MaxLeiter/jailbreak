#!/usr/bin/env bash
# Ad-hoc: build the libpulse-simple ABI smoke-test client, linking the shim dylib
# exactly as a real app would (-lpulse-simple, public headers only). Not shipped.
set -euo pipefail

SRC=/work/audio
OUT=/out
SYSROOT="${SYSROOT:-/root/cctools/SDK/iPhoneOS.sdk}"
CC="${CC:-aarch64-apple-darwin-clang}"
CFLAGS="-isysroot $SYSROOT -miphoneos-version-min=16.0 -arch arm64 -O2 -Wall -I$SRC -I$SRC/pulse"
LDFLAGS="-isysroot $SYSROOT -miphoneos-version-min=16.0 -arch arm64"

mkdir -p /tmp/t

echo "==> build shim dylib to link against"
$CC $CFLAGS -dynamiclib "$SRC/xios_audio_client.c" "$SRC/libpulse-simple-xios.c" \
    -o /tmp/t/libpulse-simple.0.dylib $LDFLAGS \
    -install_name /var/jb/usr/lib/libpulse-simple.0.dylib
ln -sf libpulse-simple.0.dylib /tmp/t/libpulse-simple.dylib

echo "==> compile pulse-shim-test (headers only, -lpulse-simple)"
$CC $CFLAGS "$SRC/pulse-shim-test.c" -o "$OUT/pulse-shim-test" -L/tmp/t -lpulse-simple $LDFLAGS

if command -v ldid >/dev/null 2>&1; then
    ldid -S"$SRC/audio.xml" "$OUT/pulse-shim-test" || ldid -S "$OUT/pulse-shim-test"
fi

echo "==> linked pulse lib:"
otool -L "$OUT/pulse-shim-test" 2>/dev/null | grep -i pulse || true
ls -l "$OUT/pulse-shim-test"
