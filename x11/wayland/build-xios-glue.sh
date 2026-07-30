#!/usr/bin/env bash
# Build libxios_glue.dylib — the shared iOS/GPU glue lib that BOTH iosc and
# Mutter's MetaBackendIOS link (design: docs/iosc-shared-glue.md). It bundles the
# hard-won iOS primitives so neither compositor forks them:
#
#   xios_surface.c        output IOSurface + app rendezvous + client IOSurface import
#   xios_egl.c            ANGLE-Metal EGL/config/context + IOSurface<->GL + EGLImage
#   xios_metal_sync.m     brokered MTLSharedEvent producer/consumer synchronization
#   xios_input_socket.c   the Xios app input-socket reader (kqueue-multiplexed)
#
# (iosc_input.c — the xkb keymap — is NOT in the glue: it is iosc-only and outside
# the xios-glue-stub.h API; Mutter maps keysyms via Clutter's own keymap.)
#
# Output (consumer's choice — both from one set of objects):
#   out/libxios_glue.a       static archive; externals (ANGLE/frameworks) resolve
#                            at the consumer's final link (no install_name/rpath)
#   out/libxios_glue.dylib   self-contained; install_name=$INSTALL_NAME (env-override)
#   out/xios-glue-include/   the headers
# MetaBackendIOS can -lxios_glue either one, or compile the .c straight into libmutter.
#
# Runs INSIDE the Procursus cross-build image, same as build-iosc.sh:
#   docker run --rm --platform linux/arm64 \
#     -v "$PWD/..:/work/x11:ro" -v "$PWD/../linux-build/out:/work/debs:ro" \
#     -v "$PWD/out:/out" procursus-xbuild:bookworm-arm64 \
#     -c "bash /work/x11/wayland/build-xios-glue.sh"
set -euo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
umask 022

X11=/work/x11
DEBS=/work/debs
WORK=/tmp/xios-glue-build
SYS="$WORK/sysroot"
# On-device runtime path recorded in the dylib (mutter's binary resolves this at
# load time). Override with INSTALL_NAME=... if the device layout differs.
INSTALL_NAME="${INSTALL_NAME:-$XIOS_PREFIX/usr/lib/libxios_glue.dylib}"
rm -rf "$WORK"; mkdir -p "$SYS" /out

echo "==> [1/4] extract dev debs into a sysroot (angle EGL/GLES)"
for pat in angle; do
  f=$(find "$DEBS" -maxdepth 1 -type f -name "${pat}_*_$XIOS_DEB_ARCH.deb" \
        | sort -V | tail -1)
  [ -n "$f" ] || { echo "!! missing deb: $pat"; exit 1; }
  dpkg-deb -x "$f" "$SYS"
  echo "   + $(basename "$f")"
done
PREFIX="$SYS$XIOS_PREFIX/usr"
ANGLE_INC="$SYS$XIOS_PREFIX/include"
ANGLE_LIB="$SYS$XIOS_PREFIX/lib/angle"
[ -f "$ANGLE_LIB/libEGL.dylib" ] || { echo "!! angle libEGL.dylib not found"; exit 1; }

echo "==> [2/4] locate the cctools cross clang"
CC=""
for cand in aarch64-apple-darwin-clang arm64-apple-darwin-clang aarch64-apple-darwin20-clang; do
  command -v "$cand" >/dev/null 2>&1 && { CC="$cand"; break; }
done
[ -n "$CC" ] || { echo "!! cctools cross clang not found on PATH"; exit 1; }
SDK="$(dirname "$(command -v "$CC")")/../SDK/iPhoneOS.sdk"
echo "   CC=$CC  SDK=$SDK  install_name=$INSTALL_NAME"

CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0 -O2 -Wall -Wextra -Wno-unused-parameter"
INCS="-I$PREFIX/include -I$ANGLE_INC -I$X11/linux-build/patches/xios -I$X11/wayland -I$X11/apps/shared"

OBJ="$WORK/obj"; mkdir -p "$OBJ"
AR="$(dirname "$(command -v "$CC")")/aarch64-apple-darwin-ar"
[ -x "$AR" ] || AR="$(command -v aarch64-apple-darwin-ar || echo ar)"

echo "==> [3/4] compile the glue objects"
compile() { echo "   cc $1"; $CC $CFLAGS $INCS -c "$2" -o "$OBJ/$1.o"; }
compile xios_surface       "$X11/linux-build/patches/xios/xios_surface.c"
compile xios_egl           "$X11/wayland/xios_egl.c"
compile xios_metal_sync    "$X11/wayland/xios_metal_sync.m"
compile xios_metal_broker  "$X11/apps/shared/XiosMetalEventBroker.m"
compile xios_input_socket  "$X11/wayland/xios_input_socket.c"
compile xios_glue_defaults "$X11/wayland/xios_glue_defaults.c"

echo "==> [4/4] emit BOTH a static archive and a dylib (consumer's choice)"
# Static .a: unresolved externals (ANGLE/frameworks) resolve at the consumer's
# final link — no install_name/rpath to manage.
rm -f /out/libxios_glue.a
"$AR" rcs /out/libxios_glue.a "$OBJ"/*.o
# Dylib: self-contained (links its ANGLE + framework deps); what a runtime
# -lxios_glue link records. install_name = $INSTALL_NAME.
$CC $CFLAGS -dynamiclib -install_name "$INSTALL_NAME" \
    "$OBJ"/*.o \
    -L"$ANGLE_LIB" -lEGL -lGLESv2 \
    -framework IOSurface -framework CoreFoundation -framework Foundation -framework Metal \
    -Wl,-rpath,$XIOS_PREFIX/lib/angle -o /out/libxios_glue.dylib
rm -rf /out/xios-glue-include; mkdir -p /out/xios-glue-include
# Ship only the canonical headers as the interface. The backend's flat
# compile-contract xios-glue-stub.h is deliberately NOT bundled;
# consumers link against these authoritative headers. build-backend-check.sh checks the
# contract against this exported input/EGL/surface surface before compiling Mutter files.
cp "$X11/linux-build/patches/xios/xios_surface.h" "$X11/wayland/xios_egl.h" \
   "$X11/wayland/xios_metal_sync.h" \
   "$X11/wayland/xios_input_socket.h" \
   /out/xios-glue-include/

echo "==> done:"
ls -l /out/libxios_glue.a /out/libxios_glue.dylib
( command -v aarch64-apple-darwin-nm >/dev/null 2>&1 && \
  echo "   exported xios_* symbols (dylib):" && \
  aarch64-apple-darwin-nm -gU /out/libxios_glue.dylib 2>/dev/null | grep -E " T _xios_" | sed 's/^/   /' | sort -u ) || true
( command -v aarch64-apple-darwin-otool >/dev/null 2>&1 && \
  echo "   dylib deps:" && aarch64-apple-darwin-otool -L /out/libxios_glue.dylib | sed 's/^/   /' ) || true
