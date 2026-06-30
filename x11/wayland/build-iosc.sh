#!/usr/bin/env bash
# Cross-compile the iosc Wayland compositor + its test client for rootless iOS.
# Runs INSIDE the Procursus cross-build image (it has the cctools aarch64 toolchain
# + iPhoneOS SDK frameworks, exactly as the Xios DDX build uses). Fire host-side:
#
#   docker run --rm --platform linux/arm64 \
#     -v "$PWD/..:/work/x11:ro" \
#     -v "$PWD/../linux-build/out:/work/debs:ro" \
#     -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 -c /work/x11/wayland/build-iosc.sh
#
# Inputs it consumes from the repo (read-only):
#   x11/wayland/iosc.c, iosc-client.c
#   x11/linux-build/patches/xios/xios_surface.{c,h}   (reused output path)
#   x11/linux-build/out/{libwayland,libepoll-shim,wayland-protocols}*.deb  (W0)
# Outputs: /out/iosc, /out/iosc-client  (unsigned Mach-O arm64; sign on device).
set -euo pipefail
umask 022

X11=/work/x11
DEBS=/work/debs
WORK=/tmp/iosc-build
SYS="$WORK/sysroot"
GEN="$WORK/gen"
rm -rf "$WORK"; mkdir -p "$SYS" "$GEN" /out

echo "==> [1/5] extract W0 dev debs into a sysroot"
for pat in libwayland-dev libwayland0 libepoll-shim-dev libepoll-shim0 wayland-protocols; do
  f=$(ls "$DEBS/${pat}_"*_iphoneos-arm64.deb 2>/dev/null | head -1 || true)
  [ -n "$f" ] || { echo "!! missing W0 deb: $pat"; exit 1; }
  dpkg-deb -x "$f" "$SYS"
  echo "   + $(basename "$f")"
done
PREFIX="$SYS/var/jb/usr"
XDG_XML="$PREFIX/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml"
[ -f "$XDG_XML" ] || { echo "!! xdg-shell.xml not found at $XDG_XML"; exit 1; }

echo "==> [2/5] host wayland-scanner (codegen only; any recent scanner is ABI-safe)"
if ! command -v wayland-scanner >/dev/null 2>&1; then
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends libwayland-bin >/dev/null 2>&1 \
    || { echo "!! could not install wayland-scanner (libwayland-bin)"; exit 1; }
fi
wayland-scanner --version 2>&1 | head -1 | sed 's/^/   scanner: /' || true

echo "==> [3/5] generate xdg-shell glue"
wayland-scanner server-header "$XDG_XML" "$GEN/xdg-shell-server-protocol.h"
wayland-scanner client-header "$XDG_XML" "$GEN/xdg-shell-client-protocol.h"
wayland-scanner private-code  "$XDG_XML" "$GEN/xdg-shell-protocol.c"
ls -1 "$GEN" | sed 's/^/   /'

echo "==> [4/5] locate the cctools cross clang"
CC=""
for cand in aarch64-apple-darwin-clang arm64-apple-darwin-clang aarch64-apple-darwin20-clang; do
  command -v "$cand" >/dev/null 2>&1 && { CC="$cand"; break; }
done
[ -n "$CC" ] || { echo "!! cctools cross clang not found on PATH"; ls /root/cctools/bin 2>/dev/null | head; exit 1; }
SDK="$(dirname "$(command -v "$CC")")/../SDK/iPhoneOS.sdk"
echo "   CC=$CC  SDK=$SDK"

CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0 -O2 -Wall -Wextra -Wno-unused-parameter"
INCS="-I$PREFIX/include -I$GEN -I$X11/linux-build/patches/xios"
RPATH="-Wl,-rpath,/var/jb/usr/lib"

echo "==> [5/5] cross-compile"
# Compositor: links libwayland-server + the Xios IOSurface output path + Apple frameworks.
$CC $CFLAGS $INCS \
    "$X11/wayland/iosc.c" \
    "$GEN/xdg-shell-protocol.c" \
    "$X11/linux-build/patches/xios/xios_surface.c" \
    -L"$PREFIX/lib" -lwayland-server \
    -framework IOSurface -framework CoreFoundation \
    $RPATH -o /out/iosc
echo "   built /out/iosc"

# Test client: links libwayland-client only (pure wl_shm, no Apple frameworks).
$CC $CFLAGS $INCS \
    "$X11/wayland/iosc-client.c" \
    "$GEN/xdg-shell-protocol.c" \
    -L"$PREFIX/lib" -lwayland-client \
    $RPATH -o /out/iosc-client
echo "   built /out/iosc-client"

echo "==> done:"
file /out/iosc /out/iosc-client 2>/dev/null || ls -l /out/iosc /out/iosc-client
echo "==> sanity: IOSurface + wayland symbols referenced by iosc"
( command -v aarch64-apple-darwin-otool >/dev/null 2>&1 && aarch64-apple-darwin-otool -L /out/iosc ) || true
