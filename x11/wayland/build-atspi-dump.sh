#!/usr/bin/env bash
# Cross-build the tiny Xios a11y helper/tools for rootless iOS.
#
# Host-side:
#   x11/wayland/build-atspi-dump.sh
#
# Output:
#   x11/wayland/out/{atspi-dump,xios-a11yd}
set -euo pipefail
umask 022

if [ "${XIOS_XBUILD_INNER:-0}" != "1" ]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  X11_DIR="$(cd "$HERE/.." && pwd)"
  REPO_ROOT="$(cd "$X11_DIR/.." && pwd)"
  IMAGE="${IOSC_XBUILD_IMAGE:-procursus-xbuild:bookworm-arm64}"
  command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found on the host" >&2; exit 1; }
  mkdir -p "$HERE/out"

  mounts=(-v "$X11_DIR:/work/x11:ro" -v "$HERE/out:/out")
  if [ -d "$X11_DIR/linux-build/out" ]; then mounts+=(-v "$X11_DIR/linux-build/out:/work/debs:ro"); fi
  if [ -d "$REPO_ROOT/repo/debs" ]; then mounts+=(-v "$REPO_ROOT/repo/debs:/work/repo-debs:ro"); fi

  docker run --rm --platform linux/arm64 -e XIOS_XBUILD_INNER=1 \
    "${mounts[@]}" "$IMAGE" -c "bash /work/x11/wayland/build-atspi-dump.sh"
  exit 0
fi

X11=/work/x11
OUT=/out
WORK=/tmp/xios-atspi-dump-build
SYS="$WORK/sysroot"
mkdir -p "$OUT"
rm -rf "$WORK"
mkdir -p "$SYS"

_x="$X11"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"

DEB_DIRS="/work/debs /work/repo-debs"
xdeb_extract "$SYS" "$DEB_DIRS" \
  libglib2.0-0 libglib2.0-dev \
  dbus \
  libatspi2.0-0 at-spi2-core-dev

if [ ! -f "$SYS/var/jb/usr/lib/pkgconfig/dbus-1.pc" ]; then
  mkdir -p "$SYS/var/jb/usr/lib/pkgconfig"
  cat > "$SYS/var/jb/usr/lib/pkgconfig/dbus-1.pc" <<'PC'
prefix=/var/jb/usr
includedir=${prefix}/include
libdir=${prefix}/lib

Name: dbus
Description: D-Bus message bus
Version: 1.14.10
Libs: -L${libdir} -ldbus-1
Cflags: -I${includedir}/dbus-1.0 -I${libdir}/dbus-1.0/include
PC
fi

mkdir -p "$SYS/var/jb/usr/lib/dbus-1.0/include/dbus"
cat > "$SYS/var/jb/usr/lib/dbus-1.0/include/dbus/dbus-arch-deps.h" <<'EOF'
#if !defined (DBUS_INSIDE_DBUS_H) && !defined (DBUS_COMPILATION)
#error "Only <dbus/dbus.h> can be included directly, this file may disappear or change contents."
#endif
#ifndef DBUS_ARCH_DEPS_H
#define DBUS_ARCH_DEPS_H
#include <dbus/dbus-macros.h>
DBUS_BEGIN_DECLS
#define DBUS_HAVE_INT64 1
_DBUS_GNUC_EXTENSION typedef long long dbus_int64_t;
_DBUS_GNUC_EXTENSION typedef unsigned long long dbus_uint64_t;
#define DBUS_INT64_CONSTANT(val)  (_DBUS_GNUC_EXTENSION val##LL)
#define DBUS_UINT64_CONSTANT(val) (_DBUS_GNUC_EXTENSION val##ULL)
typedef int dbus_int32_t;
typedef unsigned int dbus_uint32_t;
typedef short dbus_int16_t;
typedef unsigned short dbus_uint16_t;
#define DBUS_MAJOR_VERSION 1
#define DBUS_MINOR_VERSION 14
#define DBUS_MICRO_VERSION 10
#define DBUS_VERSION_STRING "1.14.10"
#define DBUS_VERSION ((1 << 16) | (14 << 8) | 10)
DBUS_END_DECLS
#endif
EOF

CC=""
for cand in aarch64-apple-darwin-clang arm64-apple-darwin-clang aarch64-apple-darwin20-clang; do
  command -v "$cand" >/dev/null 2>&1 && { CC="$cand"; break; }
done
[ -n "$CC" ] || { echo "ERROR: cross clang not found" >&2; exit 1; }
SDK="$(dirname "$(command -v "$CC")")/../SDK/iPhoneOS.sdk"

SYSROOT_ROOT="$SYS"
PREFIX="$SYS/var/jb/usr"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT_ROOT"

CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0 -O2 -Wall -Wextra -Wno-unused-parameter"
DEPFLAGS="-I$PREFIX/include/at-spi-2.0 \
  -I$PREFIX/lib/dbus-1.0/include -I$PREFIX/include/dbus-1.0 -I$X11/linux-build/src-tarballs/dbus-headers \
  -I$PREFIX/include/glib-2.0 -I$PREFIX/lib/glib-2.0/include \
  -L$PREFIX/lib -latspi -ldbus-1 -lgio-2.0 -lgobject-2.0 -lglib-2.0"
RPATH="-Wl,-rpath,/var/jb/usr/lib"

echo "==> build atspi-dump"
# shellcheck disable=SC2086
$CC $CFLAGS "$X11/wayland/atspi-dump.c" $DEPFLAGS -L"$PREFIX/lib" $RPATH -o "$OUT/atspi-dump"

echo "==> build xios-a11yd"
# shellcheck disable=SC2086
$CC $CFLAGS "$X11/wayland/xios-a11yd.c" $DEPFLAGS -L"$PREFIX/lib" $RPATH -o "$OUT/xios-a11yd"

if command -v ldid >/dev/null 2>&1; then
  ldid -S "$OUT/atspi-dump"
  ldid -S "$OUT/xios-a11yd"
fi

file "$OUT/atspi-dump" | sed 's/^/   /'
file "$OUT/xios-a11yd" | sed 's/^/   /'
echo "==> built $OUT/atspi-dump $OUT/xios-a11yd"
