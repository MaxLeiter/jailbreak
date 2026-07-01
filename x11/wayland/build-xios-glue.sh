#!/usr/bin/env bash
# Build libxios_glue — the shared iOS/GPU glue lib that BOTH iosc and Mutter's
# MetaBackendIOS link (design: docs/iosc-shared-glue.md). It bundles the four
# hard-won iOS primitives so neither compositor forks them:
#
#   xios_surface.c        output IOSurface + app rendezvous + client IOSurface import
#   xios_egl.c            ANGLE-Metal EGL/config/context + IOSurface<->GL + EGLImage
#   iosc_input.c          xkb "us" keymap + X-keysym -> evdev reverse map
#   xios_input_socket.c   the Xios app input-socket reader (kqueue-multiplexed)
#
# Output: a static archive out/libxios_glue.a + headers in out/xios-glue-include/.
# A static lib keeps framework/ANGLE resolution at the FINAL link (iosc or
# libmutter), so this build needs no dylib install_name/rpath juggling.
#
# Runs INSIDE the Procursus cross-build image, same as build-iosc.sh:
#   docker run --rm --platform linux/arm64 \
#     -v "$PWD/..:/work/x11:ro" -v "$PWD/../linux-build/out:/work/debs:ro" \
#     -v "$PWD/out:/out" procursus-xbuild:bookworm-arm64 \
#     -c "bash /work/x11/wayland/build-xios-glue.sh"
set -euo pipefail
umask 022

X11=/work/x11
DEBS=/work/debs
WORK=/tmp/xios-glue-build
SYS="$WORK/sysroot"
OBJ="$WORK/obj"
rm -rf "$WORK"; mkdir -p "$SYS" "$OBJ" /out

echo "==> [1/4] extract dev debs into a sysroot (angle EGL/GLES + xkbcommon)"
for pat in angle libxkbcommon-dev libxkbcommon0; do
  f=$(ls "$DEBS/${pat}_"*_iphoneos-arm64.deb 2>/dev/null | head -1 || true)
  [ -n "$f" ] || { echo "!! missing deb: $pat"; exit 1; }
  dpkg-deb -x "$f" "$SYS"
  echo "   + $(basename "$f")"
done
PREFIX="$SYS/var/jb/usr"
ANGLE_INC="$SYS/var/jb/include"

echo "==> [2/4] locate the cctools cross clang"
CC=""
for cand in aarch64-apple-darwin-clang arm64-apple-darwin-clang aarch64-apple-darwin20-clang; do
  command -v "$cand" >/dev/null 2>&1 && { CC="$cand"; break; }
done
[ -n "$CC" ] || { echo "!! cctools cross clang not found on PATH"; exit 1; }
AR="$(dirname "$(command -v "$CC")")/aarch64-apple-darwin-ar"
[ -x "$AR" ] || AR="$(command -v aarch64-apple-darwin-ar || echo ar)"
SDK="$(dirname "$(command -v "$CC")")/../SDK/iPhoneOS.sdk"
echo "   CC=$CC  AR=$AR  SDK=$SDK"

CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0 -O2 -Wall -Wextra -Wno-unused-parameter"
INCS="-I$PREFIX/include -I$ANGLE_INC -I$X11/linux-build/patches/xios -I$X11/wayland"

echo "==> [3/4] compile the glue translation units"
compile() {
  echo "   cc $1"
  $CC $CFLAGS $INCS -c "$2" -o "$OBJ/$1.o"
}
compile xios_surface      "$X11/linux-build/patches/xios/xios_surface.c"
compile xios_egl          "$X11/wayland/xios_egl.c"
compile iosc_input        "$X11/wayland/iosc_input.c"
compile xios_input_socket "$X11/wayland/xios_input_socket.c"

echo "==> [4/4] archive + stage headers"
rm -f /out/libxios_glue.a
"$AR" rcs /out/libxios_glue.a "$OBJ"/*.o
mkdir -p /out/xios-glue-include
cp "$X11/linux-build/patches/xios/xios_surface.h" "$X11/wayland/xios_egl.h" \
   "$X11/wayland/iosc_input.h" "$X11/wayland/xios_input_socket.h" \
   "$X11/wayland/xios-glue-stub.h" /out/xios-glue-include/

echo "==> done:"
ls -l /out/libxios_glue.a
( command -v aarch64-apple-darwin-nm >/dev/null 2>&1 && \
  echo "   exported symbols:" && \
  aarch64-apple-darwin-nm /out/libxios_glue.a 2>/dev/null | grep -E " T _xios_" | sed 's/^/   /' | sort -u ) || true
