#!/bin/bash
# Package the iosc Wayland compositor as an installable rootless-iOS deb, so the
# GPU Wayland desktop ships like the rest of the stack. Host-side: stage the tree
# and ldid-sign the binaries on macOS, then assemble the .deb with the container's
# dpkg-deb (chowned root:root). Same pipeline as ports/angle/package-angle-es3.sh.
#
#   bash x11/wayland/package-iosc.sh
#
# Inputs (built by build-iosc.sh; sign happens here, not in build-iosc.sh):
#   x11/wayland/out/iosc          the compositor (signed with the GPU set below)
#   x11/wayland/out/iosc-client   wl_shm self-test client (ad-hoc signed)
#   x11/wayland/{run-iosc.sh,run-kgx.sh,iosc-gl-ent.xml}
# Output: iosc_<ver>_iphoneos-arm64.deb in x11/linux-build/out and repo/debs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_x="$HERE"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"

WAYLAND="$HERE"
OUTDIR="$XLIB_ROOT/linux-build/out"
REPODEBS="$(cd "$XLIB_ROOT/.." && pwd)/repo/debs"
STAGEROOT=/private/tmp/iosc-deb
STAGE="$STAGEROOT/iosc"
VER="0.9.10"
ARCH="iphoneos-arm64"
DEB="iosc_${VER}_${ARCH}.deb"

BIN="$STAGE/var/jb/usr/local/bin"
SHARE="$STAGE/var/jb/usr/local/share/iosc"
LIB="$STAGE/var/jb/usr/local/lib"

rm -rf "$STAGEROOT"
mkdir -p "$BIN" "$SHARE" "$LIB" "$STAGE/DEBIAN"

# 1. compositor binary -> /var/jb/usr/local/bin, signed with the GPU entitlement
#    set (AGX/IOGPU/IOSurface IOKit + task_for_pid, NO no-container). Without these
#    iosc cannot reach the GPU and falls back to the CPU compositor; see iosc-gl-ent.xml.
cp "$WAYLAND/out/iosc" "$BIN/iosc"
chmod 0755 "$BIN/iosc"
xsign "$BIN/iosc" "$WAYLAND/iosc-gl-ent.xml" \
  platform-application com.apple.private.skip-library-validation task_for_pid-allow \
  AGXDeviceUserClient IOGPUDeviceUserClient IOSurfaceRootUserClient

# 2. wl_shm self-test client (pure software; ad-hoc sign, no entitlements needed).
#    Lets run-iosc.sh paint a test window with no GNOME app installed.
cp "$WAYLAND/out/iosc-client" "$BIN/iosc-client"
chmod 0755 "$BIN/iosc-client"
xsign "$BIN/iosc-client"

# 3. orchestration scripts (run on-device as root; reference $BIN/iosc by abs path)
cp "$WAYLAND/run-iosc.sh" "$BIN/run-iosc.sh"
cp "$WAYLAND/run-kgx.sh"  "$BIN/run-kgx.sh"
chmod 0755 "$BIN/run-iosc.sh" "$BIN/run-kgx.sh"

# 4. the GPU entitlement set, for reference / re-signing the binary if ever needed
cp "$WAYLAND/iosc-gl-ent.xml" "$SHARE/iosc-gl-ent.xml"
chmod 0644 "$SHARE/iosc-gl-ent.xml"

# 4b. the wayland-egl<->ANGLE GPU shim (libiosc_egl.dylib). This is the client-side
#     GPU path for ANY wl_egl_window client (GTK4/GSK, mpv, Qt, SDL): a drop-in libEGL
#     that forwards to ANGLE except for the Wayland platform + window-surface calls,
#     which it routes through IOSurface + iosc_iosurface (zero-copy into iosc). It is
#     installed at its own install_name here so it ships in a deb rather than being
#     hand-copied. NOTE: the load-bearing copy that GPU clients actually bind is the
#     one the `angle` deb stages AS /var/jb/lib/angle/libEGL.dylib (kgx/GTK4/mpv all
#     link/dlopen ANGLE's libEGL and transparently get the shim there); this copy is
#     the canonical standalone artifact (its build install_name) and backs the
#     iosc-egl-client self-test. Ad-hoc signed (the GPU-using *process* carries the
#     entitlements, not the dylib).
if [ -f "$WAYLAND/out/libiosc_egl.dylib" ]; then
  cp "$WAYLAND/out/libiosc_egl.dylib" "$LIB/libiosc_egl.dylib"
  chmod 0755 "$LIB/libiosc_egl.dylib"
  xsign "$LIB/libiosc_egl.dylib"
else
  echo "WARN: libiosc_egl.dylib not found at $WAYLAND/out — build-iosc.sh not run?"
fi

INSTKB=$(du -sk "$STAGE/var/jb" | cut -f1)

# 5. control
cat > "$STAGE/DEBIAN/control" <<EOF
Package: iosc
Name: iosc (Wayland compositor)
Version: ${VER}
Architecture: ${ARCH}
Maintainer: Max Leiter <maxwell.leiter@gmail.com>
Author: Max Leiter <maxwell.leiter@gmail.com>
Depends: angle, libwayland0, libxkbcommon0
Recommends: gnome-console
Section: X11
Priority: optional
Installed-Size: ${INSTKB}
Description: GPU-accelerated Wayland compositor for the Xios desktop
 iosc is a small clean-room Wayland compositor (libwayland-server) for the Xios
 desktop on rootless iOS. It composites Wayland clients on the Apple GPU through
 ANGLE and Metal and hands the finished frame to the Xios app to display, with no
 per-frame copying. It is the GPU counterpart to the Xios X11 server: where Xios
 draws X clients in software, iosc runs Wayland clients such as GTK4 and GNOME apps
 on the A10 GPU.
 .
 It advertises the protocols modern toolkits expect (xdg-shell windows and popups,
 subsurfaces, viewporter, fractional-scale, and clipboard via wl_data_device),
 stacks multiple windows with focus-on-tap, and routes touch and keyboard from the
 Xios app into the focused window so you can tap and type into a live terminal.
 Since 0.9 it also provides the shell-side protocols (wlr layer-shell,
 foreign-toplevel management and screencopy) that the iosc-shell desktop
 package builds on.
 .
 Needs the Xios app installed (the on-screen display front end) and at least one
 Wayland client to be useful. Install the gnome-console package and run run-kgx.sh
 for a GNOME terminal, or run run-iosc.sh for a dependency-free paint self-test.
 The compositor is signed with the GPU entitlement set (a copy is kept under
 /var/jb/usr/local/share/iosc). Built for iPadOS/iOS rootless (palera1n/Dopamine).
EOF

echo "=== staged tree ==="
find "$STAGE" -type f | sed "s#$STAGE##" | sort
echo "installed=${INSTKB}KB"
echo "=== iosc entitlements (should be the GPU set) ==="
ldid -e "$BIN/iosc" | grep -E "iokit-user-client-class|AGXDevice|IOGPU|no-container|task_for_pid" | sed 's/^/   /' || true

# 6. assemble the deb (root-owned, zstd) via xmkdeb — builds in the container on a
#    macOS host, or directly when already running as root inside one.
built="$(xmkdeb "$STAGE" "$OUTDIR")"
cp "$built" "$REPODEBS/${DEB}"
echo "=== DEB BUILT ==="
ls -la "$OUTDIR/${DEB}" "$REPODEBS/${DEB}"
