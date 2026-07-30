#!/usr/bin/env bash
# Cross-compile the iosc Wayland compositor + its test clients for rootless iOS.
#
# Just run it from the Mac — no docker flags to get wrong:
#
#   x11/wayland/build-iosc.sh
#
# On the host it re-execs itself inside the Procursus cross-build image (cctools
# aarch64 toolchain + iPhoneOS SDK) with every mount wired up, then signs the
# result. Inside the container (IOSC_XBUILD_INNER=1) it runs the actual build.
#
# Dev debs are read from x11/linux-build/out first, then the published repo/debs
# as a fallback, so a freshly-cleaned linux-build/out still builds. Override the
# image with IOSC_XBUILD_IMAGE; skip the auto-sign with IOSC_NO_SIGN=1.
#
# Inputs it consumes (read-only):
#   x11/wayland/iosc.c, iosc-client.c, iosc-gpu-client.c, iosc-iosurface.xml
#   x11/linux-build/patches/xios/xios_surface.{c,h}   (reused output path)
#   {libwayland,libepoll-shim,wayland-protocols,angle,libxkbcommon}*.deb
# Outputs: x11/wayland/out/{iosc, iosc-client, iosc-gpu-client}
#   iosc is signed on the host after the build (needs ldid) so it is device-ready.
set -euo pipefail
umask 022

# ---- host launcher: wire the mounts + re-exec in the image, then sign ---------
if [ "${IOSC_XBUILD_INNER:-0}" != "1" ]; then
  HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"     # x11/wayland
  X11_DIR="$(cd "$HERE/.." && pwd)"                        # x11
  REPO_ROOT="$(cd "$X11_DIR/.." && pwd)"                   # repo root
  IMAGE="${IOSC_XBUILD_IMAGE:-procursus-xbuild:bookworm-arm64}"
  command -v docker >/dev/null 2>&1 || { echo "ERROR: docker not found on the host" >&2; exit 1; }
  mkdir -p "$HERE/out"

  mounts=(-v "$X11_DIR:/work/x11:ro" -v "$HERE/out:/out")
  # Both deb dirs are mounted read-only when present; the inner build searches
  # /work/debs (linux-build/out) first, then /work/repo-debs (published repo).
  found_debs=0
  if [ -d "$X11_DIR/linux-build/out" ]; then
    mounts+=(-v "$X11_DIR/linux-build/out:/work/debs:ro"); found_debs=1
  fi
  if [ -d "$REPO_ROOT/repo/debs" ]; then
    mounts+=(-v "$REPO_ROOT/repo/debs:/work/repo-debs:ro"); found_debs=1
  fi
  [ "$found_debs" = 1 ] || {
    echo "ERROR: no deb dir found (looked for $X11_DIR/linux-build/out and $REPO_ROOT/repo/debs)" >&2
    exit 1
  }

  echo "==> cross-building iosc in $IMAGE"
  docker run --rm --platform linux/arm64 -e IOSC_XBUILD_INNER=1 \
    -e IOSC_BUILD_XWM="${IOSC_BUILD_XWM:-0}" \
    "${mounts[@]}" "$IMAGE" -c "bash /work/x11/wayland/build-iosc.sh"

  # Container output is unsigned; sign on the host so it is device-ready (the
  # single easiest thing to forget — the handoff calls it out explicitly).
  if [ "${IOSC_NO_SIGN:-0}" = "1" ]; then
    echo "==> IOSC_NO_SIGN=1: skipping host signing (binary is UNSIGNED, not device-ready)"
  elif command -v ldid >/dev/null 2>&1; then
    echo "==> signing $HERE/out/iosc for device"
    "$HERE/sign-iosc.sh" "$HERE/out/iosc"
  else
    echo "!! ldid not found on the host: iosc is UNSIGNED. Before deploying, run:" >&2
    echo "     $HERE/sign-iosc.sh $HERE/out/iosc" >&2
  fi
  exit 0
fi

# ---- inner build (runs inside the container) ----------------------------------
X11=/work/x11
WORK=/tmp/iosc-build
SYS="$WORK/sysroot"
GEN="$WORK/gen"
rm -rf "$WORK"; mkdir -p "$SYS" "$GEN" /out

# Shared helpers (xdeb_extract). Sourced via walk-up so it works at any depth,
# including inside the container where X11 is /work/x11.
_x="$X11"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"

# Deb search dirs, in priority order (either mount may be absent; first with the
# deb wins): linux-build/out then the published repo/debs.
DEB_DIRS=""
[ -d /work/debs ]      && DEB_DIRS="$DEB_DIRS /work/debs"
[ -d /work/repo-debs ] && DEB_DIRS="$DEB_DIRS /work/repo-debs"
[ -n "$DEB_DIRS" ] || { echo "!! no deb dirs mounted (/work/debs, /work/repo-debs)"; exit 1; }

echo "==> [1/5] extract W0 dev debs (+ angle for the GPU client) into a sysroot"
echo "   (searching:$DEB_DIRS)"
xdeb_extract "$SYS" "$DEB_DIRS" \
  libwayland-dev libwayland0 libepoll-shim-dev libepoll-shim0 wayland-protocols angle \
  libxkbcommon-dev libxkbcommon0 \
  libxcb1 libxcb1-dev
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
SCREENCOPY_XML="$X11/apps/iosc-shell/protocols/wlr-screencopy-unstable-v1.xml"
DATA_CONTROL_XML="$X11/apps/iosc-shell/protocols/wlr-data-control-unstable-v1.xml"
POINTER_CONSTRAINTS_XML="$PREFIX/share/wayland-protocols/unstable/pointer-constraints/pointer-constraints-unstable-v1.xml"
RELATIVE_POINTER_XML="$PREFIX/share/wayland-protocols/unstable/relative-pointer/relative-pointer-unstable-v1.xml"
POINTER_GESTURES_XML="$PREFIX/share/wayland-protocols/unstable/pointer-gestures/pointer-gestures-unstable-v1.xml"
PRIMARY_SELECTION_XML="$PREFIX/share/wayland-protocols/unstable/primary-selection/primary-selection-unstable-v1.xml"
IDLE_INHIBIT_XML="$PREFIX/share/wayland-protocols/unstable/idle-inhibit/idle-inhibit-unstable-v1.xml"
IDLE_NOTIFY_XML="$PREFIX/share/wayland-protocols/staging/ext-idle-notify/ext-idle-notify-v1.xml"
SINGLE_PIXEL_XML="$PREFIX/share/wayland-protocols/staging/single-pixel-buffer/single-pixel-buffer-v1.xml"
CURSOR_SHAPE_XML="$PREFIX/share/wayland-protocols/staging/cursor-shape/cursor-shape-v1.xml"
TABLET_XML="$PREFIX/share/wayland-protocols/stable/tablet/tablet-v2.xml"
SESSION_LOCK_XML="$PREFIX/share/wayland-protocols/staging/ext-session-lock/ext-session-lock-v1.xml"
XWLSHELL_XML="$X11/wayland/protocols/xwayland-shell-v1.xml"
KDE_OUTPUT_DEVICE_XML="$X11/wayland/protocols/kde-output-device-v2.xml"
KDE_OUTPUT_MGMT_XML="$X11/wayland/protocols/kde-output-management-v2.xml"
KDE_PRIMARY_OUTPUT_XML="$X11/wayland/protocols/kde-primary-output-v1.xml"
KDE_OUTPUT_ORDER_XML="$X11/wayland/protocols/kde-output-order-v1.xml"
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
[ -f "$SCREENCOPY_XML" ] || { echo "!! wlr-screencopy-unstable-v1.xml not found at $SCREENCOPY_XML"; exit 1; }
[ -f "$DATA_CONTROL_XML" ] || { echo "!! wlr-data-control-unstable-v1.xml not found at $DATA_CONTROL_XML"; exit 1; }
[ -f "$POINTER_CONSTRAINTS_XML" ] || { echo "!! pointer-constraints-unstable-v1.xml not found at $POINTER_CONSTRAINTS_XML"; exit 1; }
[ -f "$RELATIVE_POINTER_XML" ] || { echo "!! relative-pointer-unstable-v1.xml not found at $RELATIVE_POINTER_XML"; exit 1; }
[ -f "$POINTER_GESTURES_XML" ] || { echo "!! pointer-gestures-unstable-v1.xml not found at $POINTER_GESTURES_XML"; exit 1; }
[ -f "$PRIMARY_SELECTION_XML" ] || { echo "!! primary-selection-unstable-v1.xml not found at $PRIMARY_SELECTION_XML"; exit 1; }
[ -f "$IDLE_INHIBIT_XML" ] || { echo "!! idle-inhibit-unstable-v1.xml not found at $IDLE_INHIBIT_XML"; exit 1; }
[ -f "$IDLE_NOTIFY_XML" ] || { echo "!! ext-idle-notify-v1.xml not found at $IDLE_NOTIFY_XML"; exit 1; }
[ -f "$SINGLE_PIXEL_XML" ] || { echo "!! single-pixel-buffer-v1.xml not found at $SINGLE_PIXEL_XML"; exit 1; }
[ -f "$CURSOR_SHAPE_XML" ] || { echo "!! cursor-shape-v1.xml not found at $CURSOR_SHAPE_XML"; exit 1; }
[ -f "$TABLET_XML" ] || { echo "!! tablet-v2.xml not found at $TABLET_XML"; exit 1; }
[ -f "$SESSION_LOCK_XML" ] || { echo "!! ext-session-lock-v1.xml not found at $SESSION_LOCK_XML"; exit 1; }
[ -f "$XWLSHELL_XML" ] || { echo "!! xwayland-shell-v1.xml not found at $XWLSHELL_XML"; exit 1; }
[ -f "$KDE_OUTPUT_DEVICE_XML" ] || { echo "!! kde-output-device-v2.xml not found at $KDE_OUTPUT_DEVICE_XML"; exit 1; }
[ -f "$KDE_OUTPUT_MGMT_XML" ] || { echo "!! kde-output-management-v2.xml not found at $KDE_OUTPUT_MGMT_XML"; exit 1; }
[ -f "$KDE_PRIMARY_OUTPUT_XML" ] || { echo "!! kde-primary-output-v1.xml not found at $KDE_PRIMARY_OUTPUT_XML"; exit 1; }
[ -f "$KDE_OUTPUT_ORDER_XML" ] || { echo "!! kde-output-order-v1.xml not found at $KDE_OUTPUT_ORDER_XML"; exit 1; }
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
wayland-scanner client-header "$VIEWPORTER_XML" "$GEN/viewporter-client-protocol.h"
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
wayland-scanner server-header "$SCREENCOPY_XML" "$GEN/wlr-screencopy-unstable-v1-server-protocol.h"
wayland-scanner client-header "$SCREENCOPY_XML" "$GEN/wlr-screencopy-unstable-v1-client-protocol.h"
wayland-scanner private-code  "$SCREENCOPY_XML" "$GEN/wlr-screencopy-unstable-v1-protocol.c"
wayland-scanner server-header "$DATA_CONTROL_XML" "$GEN/wlr-data-control-unstable-v1-server-protocol.h"
wayland-scanner client-header "$DATA_CONTROL_XML" "$GEN/wlr-data-control-unstable-v1-client-protocol.h"
wayland-scanner private-code  "$DATA_CONTROL_XML" "$GEN/wlr-data-control-unstable-v1-protocol.c"
wayland-scanner server-header "$POINTER_CONSTRAINTS_XML" "$GEN/pointer-constraints-unstable-v1-server-protocol.h"
wayland-scanner private-code  "$POINTER_CONSTRAINTS_XML" "$GEN/pointer-constraints-unstable-v1-protocol.c"
wayland-scanner server-header "$RELATIVE_POINTER_XML" "$GEN/relative-pointer-unstable-v1-server-protocol.h"
wayland-scanner private-code  "$RELATIVE_POINTER_XML" "$GEN/relative-pointer-unstable-v1-protocol.c"
wayland-scanner server-header "$POINTER_GESTURES_XML" "$GEN/pointer-gestures-unstable-v1-server-protocol.h"
wayland-scanner private-code  "$POINTER_GESTURES_XML" "$GEN/pointer-gestures-unstable-v1-protocol.c"
wayland-scanner server-header "$PRIMARY_SELECTION_XML" "$GEN/primary-selection-unstable-v1-server-protocol.h"
wayland-scanner private-code  "$PRIMARY_SELECTION_XML" "$GEN/primary-selection-unstable-v1-protocol.c"
wayland-scanner server-header "$IDLE_INHIBIT_XML" "$GEN/idle-inhibit-unstable-v1-server-protocol.h"
wayland-scanner private-code  "$IDLE_INHIBIT_XML" "$GEN/idle-inhibit-unstable-v1-protocol.c"
wayland-scanner server-header "$IDLE_NOTIFY_XML" "$GEN/ext-idle-notify-v1-server-protocol.h"
wayland-scanner private-code  "$IDLE_NOTIFY_XML" "$GEN/ext-idle-notify-v1-protocol.c"
wayland-scanner server-header "$SINGLE_PIXEL_XML" "$GEN/single-pixel-buffer-v1-server-protocol.h"
wayland-scanner client-header "$SINGLE_PIXEL_XML" "$GEN/single-pixel-buffer-v1-client-protocol.h"
wayland-scanner private-code  "$SINGLE_PIXEL_XML" "$GEN/single-pixel-buffer-v1-protocol.c"
# tablet-v2 first: cursor-shape's get_tablet_tool_v2 references zwp_tablet_tool_v2_interface.
wayland-scanner server-header "$TABLET_XML" "$GEN/tablet-v2-server-protocol.h"
wayland-scanner client-header "$TABLET_XML" "$GEN/tablet-v2-client-protocol.h"
wayland-scanner private-code  "$TABLET_XML" "$GEN/tablet-v2-protocol.c"
wayland-scanner server-header "$CURSOR_SHAPE_XML" "$GEN/cursor-shape-v1-server-protocol.h"
wayland-scanner client-header "$CURSOR_SHAPE_XML" "$GEN/cursor-shape-v1-client-protocol.h"
wayland-scanner private-code  "$CURSOR_SHAPE_XML" "$GEN/cursor-shape-v1-protocol.c"
wayland-scanner server-header "$SESSION_LOCK_XML" "$GEN/ext-session-lock-v1-server-protocol.h"
wayland-scanner client-header "$SESSION_LOCK_XML" "$GEN/ext-session-lock-v1-client-protocol.h"
wayland-scanner private-code  "$SESSION_LOCK_XML" "$GEN/ext-session-lock-v1-protocol.c"
# xwayland-shell-v1: the surface<->X-window association global (rootless XWM).
wayland-scanner server-header "$XWLSHELL_XML" "$GEN/xwayland-shell-v1-server-protocol.h"
wayland-scanner private-code  "$XWLSHELL_XML" "$GEN/xwayland-shell-v1-protocol.c"
# KDE output-management family (kscreen-doctor/libkscreen/plasma reconfigure our output).
# device-v2 defines both kde_output_device_v2 and kde_output_device_mode_v2; the
# management/primary/order .c files reference those interfaces externally.
wayland-scanner server-header "$KDE_OUTPUT_DEVICE_XML" "$GEN/kde-output-device-v2-server-protocol.h"
wayland-scanner private-code  "$KDE_OUTPUT_DEVICE_XML" "$GEN/kde-output-device-v2-protocol.c"
wayland-scanner server-header "$KDE_OUTPUT_MGMT_XML" "$GEN/kde-output-management-v2-server-protocol.h"
wayland-scanner private-code  "$KDE_OUTPUT_MGMT_XML" "$GEN/kde-output-management-v2-protocol.c"
wayland-scanner server-header "$KDE_PRIMARY_OUTPUT_XML" "$GEN/kde-primary-output-v1-server-protocol.h"
wayland-scanner private-code  "$KDE_PRIMARY_OUTPUT_XML" "$GEN/kde-primary-output-v1-protocol.c"
wayland-scanner server-header "$KDE_OUTPUT_ORDER_XML" "$GEN/kde-output-order-v1-server-protocol.h"
wayland-scanner private-code  "$KDE_OUTPUT_ORDER_XML" "$GEN/kde-output-order-v1-protocol.c"
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

CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0 -O2 -Wall -Wextra -Wno-unused-parameter -fblocks"
INCS="-I$PREFIX/include -I$GEN -I$X11/linux-build/patches/xios -I$X11/apps/shared"
RPATH="-Wl,-rpath,/var/jb/usr/lib"
XWM_CFLAGS=()
XWM_SRCS=()
XWM_LIBS=()
if [ "${IOSC_BUILD_XWM:-0}" = "1" ]; then
  XWM_CFLAGS=(-DIOSC_ENABLE_XWM=1)
  XWM_SRCS=("$X11/wayland/iosc_xwm.c")
  XWM_LIBS=(-lxcb)
  echo "   XWM: enabled (links libxcb)"
else
  echo "   XWM: disabled (set IOSC_BUILD_XWM=1 to include rootless Xwayland XWM)"
fi

echo "==> [5/5] cross-compile"
# Compositor: libwayland-server + xdg-shell + our iosc_iosurface + the Xios IOSurface
# output path (which now also does the client->server IOSurface import) + the ANGLE GPU
# compositor (iosc_gl.c: GLES->Metal composite onto the output IOSurface) + frameworks.
$CC $CFLAGS "${XWM_CFLAGS[@]}" $INCS -I"$ANGLE_INC" \
    "$X11/wayland/iosc.c" \
    "$X11/wayland/iosc_options.c" \
    "$X11/wayland/iosc_render_plan.c" \
    "$X11/wayland/iosc_util.c" \
    "$X11/wayland/iosc_iosurface.c" \
    "$X11/wayland/iosc-clipboard-bridge.c" \
    "${XWM_SRCS[@]}" \
    "$X11/wayland/iosc_gl.c" \
    "$X11/wayland/xios_egl.c" \
    "$X11/wayland/xios_metal_sync.m" \
    "$X11/apps/shared/XiosMetalEventBroker.m" \
    "$X11/apps/shared/iosc_status.c" \
    "$X11/wayland/xios_canvas.c" \
    "$X11/wayland/iosc_input.c" \
    "$X11/wayland/xios_input_socket.c" \
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
    "$GEN/pointer-constraints-unstable-v1-protocol.c" \
    "$GEN/relative-pointer-unstable-v1-protocol.c" \
    "$GEN/pointer-gestures-unstable-v1-protocol.c" \
    "$GEN/primary-selection-unstable-v1-protocol.c" \
    "$GEN/idle-inhibit-unstable-v1-protocol.c" \
    "$GEN/ext-idle-notify-v1-protocol.c" \
    "$GEN/single-pixel-buffer-v1-protocol.c" \
    "$GEN/tablet-v2-protocol.c" \
    "$GEN/cursor-shape-v1-protocol.c" \
    "$GEN/wlr-screencopy-unstable-v1-protocol.c" \
    "$GEN/wlr-data-control-unstable-v1-protocol.c" \
    "$GEN/ext-session-lock-v1-protocol.c" \
    "$GEN/xwayland-shell-v1-protocol.c" \
    "$GEN/kde-output-device-v2-protocol.c" \
    "$GEN/kde-output-management-v2-protocol.c" \
    "$GEN/kde-primary-output-v1-protocol.c" \
    "$GEN/kde-output-order-v1-protocol.c" \
    "$GEN/iosc-iosurface-protocol.c" \
    "$X11/linux-build/patches/xios/xios_surface.c" \
    -L"$PREFIX/lib" -lwayland-server -lxkbcommon "${XWM_LIBS[@]}" \
    -L"$ANGLE_LIB" -lEGL -lGLESv2 \
    -framework IOSurface -framework CoreFoundation -framework Foundation -framework Metal \
    $RPATH -Wl,-rpath,/var/jb/lib/angle -o /out/iosc
echo "   built /out/iosc"

# Package-owned Mach-service broker. MTLSharedEventHandle is transported by
# NSXPC exactly once; high-frequency frame values remain on the existing wires.
$CC $CFLAGS \
    "$X11/wayland/xios-metal-event-broker.m" \
    -framework Foundation -framework Metal \
    -o /out/xios-metal-event-broker
echo "   built /out/xios-metal-event-broker"

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

# single-pixel-buffer test client: 1x1 solid colour scaled via viewporter (no wl_shm).
$CC $CFLAGS $INCS \
    "$X11/wayland/iosc-spb-test.c" \
    "$GEN/single-pixel-buffer-v1-protocol.c" \
    "$GEN/viewporter-protocol.c" \
    "$GEN/xdg-shell-protocol.c" \
    -L"$PREFIX/lib" -lwayland-client \
    $RPATH -o /out/iosc-spb-test
echo "   built /out/iosc-spb-test"

# drag-and-drop test client: press-drag-release inside its window self-drops a
# text/plain payload through the full data_device flow; --no-drag = pure target.
$CC $CFLAGS $INCS \
    "$X11/wayland/iosc-dnd-test.c" \
    "$GEN/xdg-shell-protocol.c" \
    -L"$PREFIX/lib" -lwayland-client \
    $RPATH -o /out/iosc-dnd-test
echo "   built /out/iosc-dnd-test"

# touch test client: prints wl_touch events; drive with iosc-input-test -t.
$CC $CFLAGS $INCS \
    "$X11/wayland/iosc-touch-test.c" \
    "$GEN/xdg-shell-protocol.c" \
    -L"$PREFIX/lib" -lwayland-client \
    $RPATH -o /out/iosc-touch-test
echo "   built /out/iosc-touch-test"

# mutter pointer logger: fullscreen shm toplevel that logs wl_pointer
# enter/motion/button and writes /var/jb/tmp/mutter-pointer-hit on press;
# the dispatch-validation probe from docs/handoff/mutter.md.
$CC $CFLAGS $INCS \
    "$X11/wayland/mutter-pointer-test.c" \
    "$GEN/xdg-shell-protocol.c" \
    -L"$PREFIX/lib" -lwayland-client \
    $RPATH -o /out/mutter-pointer-test
echo "   built /out/mutter-pointer-test"

# tablet test client: prints zwp_tablet_tool_v2 pen strokes with pressure/tilt;
# drive with iosc-input-test -p.
$CC $CFLAGS $INCS \
    "$X11/wayland/iosc-tablet-test.c" \
    "$GEN/tablet-v2-protocol.c" \
    "$GEN/xdg-shell-protocol.c" \
    -L"$PREFIX/lib" -lwayland-client \
    $RPATH -o /out/iosc-tablet-test
echo "   built /out/iosc-tablet-test"

# session-lock test client: locks, shows a red lock screen for 10s, unlocks.
$CC $CFLAGS $INCS \
    "$X11/wayland/iosc-lock-test.c" \
    "$GEN/ext-session-lock-v1-protocol.c" \
    -L"$PREFIX/lib" -lwayland-client \
    $RPATH -o /out/iosc-lock-test
echo "   built /out/iosc-lock-test"

# screencopy test client: captures the whole output into wl_shm + prints a probe.
$CC $CFLAGS $INCS \
    "$X11/wayland/iosc-screenshot-test.c" \
    "$GEN/wlr-screencopy-unstable-v1-protocol.c" \
    -L"$PREFIX/lib" -lwayland-client \
    $RPATH -o /out/iosc-screenshot-test
echo "   built /out/iosc-screenshot-test"

# GPU test client: renders GLES->IOSurface via ANGLE, hands it over iosc_iosurface.
$CC $CFLAGS $INCS -I"$ANGLE_INC" \
    "$X11/wayland/iosc-gpu-client.c" \
    "$X11/wayland/xios_metal_sync.m" \
    "$X11/apps/shared/XiosMetalEventBroker.m" \
    "$GEN/xdg-shell-protocol.c" \
    "$GEN/iosc-iosurface-protocol.c" \
    -L"$PREFIX/lib" -lwayland-client \
    -L"$ANGLE_LIB" -lEGL -lGLESv2 \
    -framework IOSurface -framework CoreFoundation -framework Foundation -framework Metal \
    -Wl,-rpath,/var/jb/usr/lib -Wl,-rpath,/var/jb/lib/angle -o /out/iosc-gpu-client
echo "   built /out/iosc-gpu-client"

# wayland-egl↔ANGLE shim (libiosc_egl.dylib): a libEGL that forwards to ANGLE and
# routes window surfaces through IOSurface + iosc_iosurface. dlopens the real
# ANGLE libEGL at runtime (not linked); links libwayland-client + GLESv2 + frameworks.
$CC $CFLAGS $INCS -I"$ANGLE_INC" \
    -dynamiclib -install_name /var/jb/usr/local/lib/libiosc_egl.dylib \
    "$X11/wayland/iosc_egl_shim.c" \
    "$X11/wayland/xios_metal_sync.m" \
    "$X11/apps/shared/XiosMetalEventBroker.m" \
    "$GEN/iosc-iosurface-protocol.c" \
    -L"$PREFIX/lib" -lwayland-client \
    -L"$ANGLE_LIB" -lGLESv2 \
    -framework IOSurface -framework CoreFoundation -framework Foundation -framework Metal \
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
