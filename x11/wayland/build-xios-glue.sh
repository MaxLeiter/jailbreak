#!/usr/bin/env bash
# Build libxios_glue.dylib — the shared iOS/GPU glue lib that BOTH iosc and
# Mutter's MetaBackendIOS link (design: docs/iosc-shared-glue.md). It bundles the
# hard-won iOS primitives so neither compositor forks them:
#
#   xios_surface.c        output IOSurface + app rendezvous + client IOSurface import
#   xios_egl.c            ANGLE-Metal EGL/config/context + IOSurface<->GL + EGLImage
#   xios_input_socket.c   the Xios app input-socket reader (kqueue-multiplexed)
#
# (iosc_input.c — the xkb keymap — is NOT in the glue: it is iosc-only and outside
# the xios-glue-stub.h API; Mutter maps keysyms via Clutter's own keymap.)
#
# Output: out/libxios_glue.dylib (install_name = $INSTALL_NAME, override via env) +
# headers in out/xios-glue-include/. A dylib is what MetaBackendIOS links against;
# its ANGLE + framework deps are resolved here so the final libmutter link is clean.
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
# On-device runtime path recorded in the dylib (mutter's binary resolves this at
# load time). Override with INSTALL_NAME=... if the device layout differs.
INSTALL_NAME="${INSTALL_NAME:-/var/jb/usr/lib/libxios_glue.dylib}"
rm -rf "$WORK"; mkdir -p "$SYS" /out

echo "==> [1/3] extract dev debs into a sysroot (angle EGL/GLES)"
for pat in angle; do
  f=$(ls "$DEBS/${pat}_"*_iphoneos-arm64.deb 2>/dev/null | head -1 || true)
  [ -n "$f" ] || { echo "!! missing deb: $pat"; exit 1; }
  dpkg-deb -x "$f" "$SYS"
  echo "   + $(basename "$f")"
done
PREFIX="$SYS/var/jb/usr"
ANGLE_INC="$SYS/var/jb/include"
ANGLE_LIB="$SYS/var/jb/lib/angle"
[ -f "$ANGLE_LIB/libEGL.dylib" ] || { echo "!! angle libEGL.dylib not found"; exit 1; }

echo "==> [2/3] locate the cctools cross clang"
CC=""
for cand in aarch64-apple-darwin-clang arm64-apple-darwin-clang aarch64-apple-darwin20-clang; do
  command -v "$cand" >/dev/null 2>&1 && { CC="$cand"; break; }
done
[ -n "$CC" ] || { echo "!! cctools cross clang not found on PATH"; exit 1; }
SDK="$(dirname "$(command -v "$CC")")/../SDK/iPhoneOS.sdk"
echo "   CC=$CC  SDK=$SDK  install_name=$INSTALL_NAME"

CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0 -O2 -Wall -Wextra -Wno-unused-parameter"
INCS="-I$PREFIX/include -I$ANGLE_INC -I$X11/linux-build/patches/xios -I$X11/wayland"

echo "==> [3/3] link the glue dylib (ANGLE EGL/GLES + IOSurface/CoreFoundation)"
$CC $CFLAGS $INCS \
    -dynamiclib -install_name "$INSTALL_NAME" \
    "$X11/linux-build/patches/xios/xios_surface.c" \
    "$X11/wayland/xios_egl.c" \
    "$X11/wayland/xios_input_socket.c" \
    "$X11/wayland/xios_glue_defaults.c" \
    -L"$ANGLE_LIB" -lEGL -lGLESv2 \
    -framework IOSurface -framework CoreFoundation \
    -Wl,-rpath,/var/jb/lib/angle -o /out/libxios_glue.dylib
mkdir -p /out/xios-glue-include
cp "$X11/linux-build/patches/xios/xios_surface.h" "$X11/wayland/xios_egl.h" \
   "$X11/wayland/xios_input_socket.h" "$X11/wayland/xios-glue-stub.h" \
   /out/xios-glue-include/

echo "==> done:"
file /out/libxios_glue.dylib 2>/dev/null || ls -l /out/libxios_glue.dylib
( command -v aarch64-apple-darwin-nm >/dev/null 2>&1 && \
  echo "   exported xios_* symbols:" && \
  aarch64-apple-darwin-nm -gU /out/libxios_glue.dylib 2>/dev/null | grep -E " T _xios_" | sed 's/^/   /' | sort -u ) || true
( command -v aarch64-apple-darwin-otool >/dev/null 2>&1 && \
  echo "   dylib deps:" && aarch64-apple-darwin-otool -L /out/libxios_glue.dylib | sed 's/^/   /' ) || true
