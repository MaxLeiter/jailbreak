#!/usr/bin/env bash
# Cross-compile the iosc Wayland compositor + its test clients for rootless iOS.
# Runs INSIDE the Procursus cross-build image (it has the cctools aarch64 toolchain
# + iPhoneOS SDK frameworks, exactly as the Xios DDX build uses). Fire host-side:
#
#   docker run --rm --platform linux/arm64 \
#     -v "$PWD/..:/work/x11:ro" \
#     -v "$PWD/../linux-build/out:/work/debs:ro" \
#     -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 -c "bash /work/x11/wayland/build-iosc.sh"
#
# Inputs it consumes from the repo (read-only):
#   x11/wayland/iosc.c, iosc-client.c, iosc-gpu-client.c, iosc-iosurface.xml
#   x11/linux-build/patches/xios/xios_surface.{c,h}   (reused output path)
#   x11/linux-build/out/{libwayland,libepoll-shim,wayland-protocols,angle}*.deb
# Outputs: /out/{iosc, iosc-client, iosc-gpu-client}  (unsigned Mach-O arm64; sign on device).
set -euo pipefail
umask 022

X11=/work/x11
DEBS=/work/debs
WORK=/tmp/iosc-build
SYS="$WORK/sysroot"
GEN="$WORK/gen"
rm -rf "$WORK"; mkdir -p "$SYS" "$GEN" /out

echo "==> [1/5] extract W0 dev debs (+ angle for the GPU client) into a sysroot"
for pat in libwayland-dev libwayland0 libepoll-shim-dev libepoll-shim0 wayland-protocols angle \
           libxkbcommon-dev libxkbcommon0; do
  f=$(ls "$DEBS/${pat}_"*_iphoneos-arm64.deb 2>/dev/null | head -1 || true)
  [ -n "$f" ] || { echo "!! missing deb: $pat"; exit 1; }
  dpkg-deb -x "$f" "$SYS"
  echo "   + $(basename "$f")"
done
PREFIX="$SYS/var/jb/usr"       # wayland headers/libs
ANGLE_INC="$SYS/var/jb/include" # angle EGL/GLES headers
ANGLE_LIB="$SYS/var/jb/lib/angle"
XDG_XML="$PREFIX/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml"
DECORATION_XML="$PREFIX/share/wayland-protocols/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml"
ACTIVATION_XML="$PREFIX/share/wayland-protocols/staging/xdg-activation/xdg-activation-v1.xml"
VIEWPORTER_XML="$PREFIX/share/wayland-protocols/stable/viewporter/viewporter.xml"
FRACTIONAL_XML="$PREFIX/share/wayland-protocols/staging/fractional-scale/fractional-scale-v1.xml"
PRESENTATION_XML="$PREFIX/share/wayland-protocols/stable/presentation-time/presentation-time.xml"
XDG_OUTPUT_XML="$PREFIX/share/wayland-protocols/unstable/xdg-output/xdg-output-unstable-v1.xml"
TEXT_INPUT_XML="$PREFIX/share/wayland-protocols/unstable/text-input/text-input-unstable-v3.xml"
INPUT_METHOD_XML="$X11/wayland/protocols/input-method-unstable-v2.xml"
VIRTUAL_KEYBOARD_XML="$X11/wayland/protocols/virtual-keyboard-unstable-v1.xml"
LAYER_SHELL_XML="$X11/apps/iosc-shell/protocols/wlr-layer-shell-unstable-v1.xml"
FOREIGN_TOPLEVEL_XML="$X11/apps/iosc-shell/protocols/wlr-foreign-toplevel-management-unstable-v1.xml"
[ -f "$XDG_XML" ] || { echo "!! xdg-shell.xml not found at $XDG_XML"; exit 1; }
[ -f "$DECORATION_XML" ] || { echo "!! xdg-decoration-unstable-v1.xml not found at $DECORATION_XML"; exit 1; }
[ -f "$ACTIVATION_XML" ] || { echo "!! xdg-activation-v1.xml not found at $ACTIVATION_XML"; exit 1; }
[ -f "$VIEWPORTER_XML" ] || { echo "!! viewporter.xml not found at $VIEWPORTER_XML"; exit 1; }
[ -f "$FRACTIONAL_XML" ] || { echo "!! fractional-scale-v1.xml not found at $FRACTIONAL_XML"; exit 1; }
[ -f "$PRESENTATION_XML" ] || { echo "!! presentation-time.xml not found at $PRESENTATION_XML"; exit 1; }
[ -f "$XDG_OUTPUT_XML" ] || { echo "!! xdg-output-unstable-v1.xml not found at $XDG_OUTPUT_XML"; exit 1; }
[ -f "$TEXT_INPUT_XML" ] || { echo "!! text-input-unstable-v3.xml not found at $TEXT_INPUT_XML"; exit 1; }
[ -f "$INPUT_METHOD_XML" ] || { echo "!! input-method-unstable-v2.xml not found at $INPUT_METHOD_XML"; exit 1; }
[ -f "$VIRTUAL_KEYBOARD_XML" ] || { echo "!! virtual-keyboard-unstable-v1.xml not found at $VIRTUAL_KEYBOARD_XML"; exit 1; }
[ -f "$LAYER_SHELL_XML" ] || { echo "!! wlr-layer-shell-unstable-v1.xml not found at $LAYER_SHELL_XML"; exit 1; }
[ -f "$FOREIGN_TOPLEVEL_XML" ] || { echo "!! wlr-foreign-toplevel-management-unstable-v1.xml not found at $FOREIGN_TOPLEVEL_XML"; exit 1; }
[ -f "$ANGLE_LIB/libEGL.dylib" ] || { echo "!! angle libEGL.dylib not found"; exit 1; }

echo "==> [2/5] host wayland-scanner (codegen only; any recent scanner is ABI-safe)"
if ! command -v wayland-scanner >/dev/null 2>&1; then
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends libwayland-bin >/dev/null 2>&1 \
    || { echo "!! could not install wayland-scanner (libwayland-bin)"; exit 1; }
fi
wayland-scanner --version 2>&1 | head -1 | sed 's/^/   scanner: /' || true

echo "==> [3/5] generate protocol glue (xdg-shell + our iosc_iosurface)"
wayland-scanner server-header "$XDG_XML" "$GEN/xdg-shell-server-protocol.h"
wayland-scanner client-header "$XDG_XML" "$GEN/xdg-shell-client-protocol.h"
wayland-scanner private-code  "$XDG_XML" "$GEN/xdg-shell-protocol.c"
wayland-scanner server-header "$DECORATION_XML" "$GEN/xdg-decoration-unstable-v1-server-protocol.h"
wayland-scanner private-code  "$DECORATION_XML" "$GEN/xdg-decoration-unstable-v1-protocol.c"
wayland-scanner server-header "$ACTIVATION_XML" "$GEN/xdg-activation-v1-server-protocol.h"
wayland-scanner private-code  "$ACTIVATION_XML" "$GEN/xdg-activation-v1-protocol.c"
wayland-scanner server-header "$VIEWPORTER_XML" "$GEN/viewporter-server-protocol.h"
wayland-scanner private-code  "$VIEWPORTER_XML" "$GEN/viewporter-protocol.c"
wayland-scanner server-header "$FRACTIONAL_XML" "$GEN/fractional-scale-v1-server-protocol.h"
wayland-scanner private-code  "$FRACTIONAL_XML" "$GEN/fractional-scale-v1-protocol.c"
wayland-scanner server-header "$PRESENTATION_XML" "$GEN/presentation-time-server-protocol.h"
wayland-scanner private-code  "$PRESENTATION_XML" "$GEN/presentation-time-protocol.c"
wayland-scanner server-header "$XDG_OUTPUT_XML" "$GEN/xdg-output-unstable-v1-server-protocol.h"
wayland-scanner private-code  "$XDG_OUTPUT_XML" "$GEN/xdg-output-unstable-v1-protocol.c"
wayland-scanner server-header "$TEXT_INPUT_XML" "$GEN/text-input-unstable-v3-server-protocol.h"
wayland-scanner private-code  "$TEXT_INPUT_XML" "$GEN/text-input-unstable-v3-protocol.c"
wayland-scanner server-header "$INPUT_METHOD_XML" "$GEN/input-method-unstable-v2-server-protocol.h"
wayland-scanner client-header "$INPUT_METHOD_XML" "$GEN/input-method-unstable-v2-client-protocol.h"
wayland-scanner private-code  "$INPUT_METHOD_XML" "$GEN/input-method-unstable-v2-protocol.c"
wayland-scanner server-header "$VIRTUAL_KEYBOARD_XML" "$GEN/virtual-keyboard-unstable-v1-server-protocol.h"
wayland-scanner client-header "$VIRTUAL_KEYBOARD_XML" "$GEN/virtual-keyboard-unstable-v1-client-protocol.h"
wayland-scanner private-code  "$VIRTUAL_KEYBOARD_XML" "$GEN/virtual-keyboard-unstable-v1-protocol.c"
wayland-scanner server-header "$LAYER_SHELL_XML" "$GEN/wlr-layer-shell-unstable-v1-server-protocol.h"
wayland-scanner client-header "$LAYER_SHELL_XML" "$GEN/wlr-layer-shell-unstable-v1-client-protocol.h"
wayland-scanner private-code  "$LAYER_SHELL_XML" "$GEN/wlr-layer-shell-unstable-v1-protocol.c"
wayland-scanner server-header "$FOREIGN_TOPLEVEL_XML" "$GEN/wlr-foreign-toplevel-management-unstable-v1-server-protocol.h"
wayland-scanner client-header "$FOREIGN_TOPLEVEL_XML" "$GEN/wlr-foreign-toplevel-management-unstable-v1-client-protocol.h"
wayland-scanner private-code  "$FOREIGN_TOPLEVEL_XML" "$GEN/wlr-foreign-toplevel-management-unstable-v1-protocol.c"
ISO_XML="$X11/wayland/iosc-iosurface.xml"
wayland-scanner server-header "$ISO_XML" "$GEN/iosc-iosurface-server-protocol.h"
wayland-scanner client-header "$ISO_XML" "$GEN/iosc-iosurface-client-protocol.h"
wayland-scanner private-code  "$ISO_XML" "$GEN/iosc-iosurface-protocol.c"
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
# Compositor: libwayland-server + xdg-shell + our iosc_iosurface + the Xios IOSurface
# output path (which now also does the client->server IOSurface import) + the ANGLE GPU
# compositor (iosc_gl.c: GLES->Metal composite onto the output IOSurface) + frameworks.
$CC $CFLAGS $INCS -I"$ANGLE_INC" \
    "$X11/wayland/iosc.c" \
    "$X11/wayland/iosc_gl.c" \
    "$X11/wayland/xios_egl.c" \
    "$X11/wayland/iosc_input.c" \
    "$GEN/xdg-shell-protocol.c" \
    "$GEN/xdg-decoration-unstable-v1-protocol.c" \
    "$GEN/xdg-activation-v1-protocol.c" \
    "$GEN/viewporter-protocol.c" \
    "$GEN/fractional-scale-v1-protocol.c" \
    "$GEN/presentation-time-protocol.c" \
    "$GEN/xdg-output-unstable-v1-protocol.c" \
    "$GEN/text-input-unstable-v3-protocol.c" \
    "$GEN/input-method-unstable-v2-protocol.c" \
    "$GEN/virtual-keyboard-unstable-v1-protocol.c" \
    "$GEN/wlr-layer-shell-unstable-v1-protocol.c" \
    "$GEN/wlr-foreign-toplevel-management-unstable-v1-protocol.c" \
    "$GEN/iosc-iosurface-protocol.c" \
    "$X11/linux-build/patches/xios/xios_surface.c" \
    -L"$PREFIX/lib" -lwayland-server -lxkbcommon \
    -L"$ANGLE_LIB" -lEGL -lGLESv2 \
    -framework IOSurface -framework CoreFoundation \
    $RPATH -Wl,-rpath,/var/jb/lib/angle -o /out/iosc
echo "   built /out/iosc"

# Input injector: a tiny client that writes the iosc input-socket protocol (no
# Wayland) so keyboard/pointer dispatch can be tested without the Xios app.
$CC $CFLAGS \
    "$X11/wayland/iosc-input-test.c" \
    $RPATH -o /out/iosc-input-test
echo "   built /out/iosc-input-test"

# External-compositor input bridge: listens for the same Xios input socket as
# iosc, then forwards text/keys through input-method-v2 + virtual-keyboard-v1.
$CC $CFLAGS $INCS \
    "$X11/wayland/ios-inputd.c" \
    "$X11/wayland/iosc_input.c" \
    "$GEN/input-method-unstable-v2-protocol.c" \
    "$GEN/virtual-keyboard-unstable-v1-protocol.c" \
    -L"$PREFIX/lib" -lwayland-client -lxkbcommon \
    $RPATH -o /out/ios-inputd
echo "   built /out/ios-inputd"

# wl_shm test client (pure software; no Apple frameworks).
$CC $CFLAGS $INCS \
    "$X11/wayland/iosc-client.c" \
    "$GEN/xdg-shell-protocol.c" \
    -L"$PREFIX/lib" -lwayland-client \
    $RPATH -o /out/iosc-client
echo "   built /out/iosc-client"

# layer-shell test client: an anchored top-edge panel to validate §5.1
# (configure handshake + anchored placement + exclusive-zone/work-area + banding).
$CC $CFLAGS $INCS \
    "$X11/wayland/iosc-layer-test.c" \
    "$GEN/wlr-layer-shell-unstable-v1-protocol.c" \
    "$GEN/xdg-shell-protocol.c" \
    -L"$PREFIX/lib" -lwayland-client \
    $RPATH -o /out/iosc-layer-test
echo "   built /out/iosc-layer-test"

# foreign-toplevel test client: bind the manager, list open windows, and
# optionally activate/close one -- validates §5.2 (the taskbar side).
$CC $CFLAGS $INCS \
    "$X11/wayland/iosc-ftl-test.c" \
    "$GEN/wlr-foreign-toplevel-management-unstable-v1-protocol.c" \
    -L"$PREFIX/lib" -lwayland-client \
    $RPATH -o /out/iosc-ftl-test
echo "   built /out/iosc-ftl-test"

# GPU test client: renders GLES->IOSurface via ANGLE, hands it over iosc_iosurface.
$CC $CFLAGS $INCS -I"$ANGLE_INC" \
    "$X11/wayland/iosc-gpu-client.c" \
    "$GEN/xdg-shell-protocol.c" \
    "$GEN/iosc-iosurface-protocol.c" \
    -L"$PREFIX/lib" -lwayland-client \
    -L"$ANGLE_LIB" -lEGL -lGLESv2 \
    -framework IOSurface -framework CoreFoundation \
    -Wl,-rpath,/var/jb/usr/lib -Wl,-rpath,/var/jb/lib/angle -o /out/iosc-gpu-client
echo "   built /out/iosc-gpu-client"

# wayland-egl↔ANGLE shim (libiosc_egl.dylib): a libEGL that forwards to ANGLE and
# routes window surfaces through IOSurface + iosc_iosurface. dlopens ANGLE libEGL
# at runtime (not linked); links libwayland-client + GLESv2 (glFinish) + frameworks.
$CC $CFLAGS $INCS -I"$ANGLE_INC" \
    -dynamiclib -install_name /var/jb/usr/local/lib/libiosc_egl.dylib \
    "$X11/wayland/iosc_egl_shim.c" \
    "$GEN/iosc-iosurface-protocol.c" \
    -L"$PREFIX/lib" -lwayland-client \
    -L"$ANGLE_LIB" -lGLESv2 \
    -framework IOSurface -framework CoreFoundation \
    -Wl,-rpath,/var/jb/usr/lib -Wl,-rpath,/var/jb/lib/angle -o /out/libiosc_egl.dylib
echo "   built /out/libiosc_egl.dylib"

# EGL test client: standard wl_egl_window + EGL window-surface API against the shim
# (NO direct ANGLE EGL link — EGL symbols resolve to the shim). Validates the shim.
$CC $CFLAGS $INCS -I"$ANGLE_INC" \
    "$X11/wayland/iosc-egl-client.c" \
    "$GEN/xdg-shell-protocol.c" \
    -L"$PREFIX/lib" -lwayland-client -lwayland-egl \
    -L/out -liosc_egl \
    -L"$ANGLE_LIB" -lGLESv2 \
    -Wl,-rpath,/var/jb/usr/lib -Wl,-rpath,/var/jb/lib/angle -Wl,-rpath,/var/jb/usr/local/lib \
    -o /out/iosc-egl-client
echo "   built /out/iosc-egl-client"

echo "==> done:"
file /out/iosc /out/iosc-client /out/iosc-gpu-client 2>/dev/null \
  || ls -l /out/iosc /out/iosc-client /out/iosc-gpu-client
echo "==> sanity: libs referenced by iosc-gpu-client"
( command -v aarch64-apple-darwin-otool >/dev/null 2>&1 && aarch64-apple-darwin-otool -L /out/iosc-gpu-client ) || true
