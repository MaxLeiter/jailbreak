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
#   x11/wayland/out/iosc-input-test diagnostic input injector (ad-hoc signed)
#   x11/wayland/out/ios-inputd    external-compositor input bridge (ad-hoc signed)
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
VER="0.9.37"
ARCH="iphoneos-arm64"
DEB="iosc_${VER}_${ARCH}.deb"

BIN="$STAGE/var/jb/usr/local/bin"
SHARE="$STAGE/var/jb/usr/local/share/iosc"
LIB="$STAGE/var/jb/usr/local/lib"
LIBEXEC="$STAGE/var/jb/usr/local/libexec"
LAUNCHD="$STAGE/var/jb/Library/LaunchDaemons"
APPS="$STAGE/var/jb/usr/share/applications"

rm -rf "$STAGEROOT"
mkdir -p "$BIN" "$SHARE" "$LIB" "$LIBEXEC" "$LAUNCHD" "$APPS" "$STAGE/DEBIAN"

# 1. compositor binary -> /var/jb/usr/local/bin, signed with the GPU entitlement
#    set (AGX/IOGPU/IOSurface IOKit + task_for_pid, NO no-container). Without these
#    iosc cannot reach the GPU and fails closed; see iosc-gl-ent.xml.
cp "$WAYLAND/out/iosc" "$BIN/iosc"
chmod 0755 "$BIN/iosc"
xsign "$BIN/iosc" "$WAYLAND/iosc-gl-ent.xml" \
  platform-application com.apple.private.skip-library-validation task_for_pid-allow \
  AGXDeviceUserClient IOGPUDeviceUserClient IOSurfaceRootUserClient

# One-time MTLSharedEventHandle transport. launchd owns the named Mach service;
# frame values continue on the Wayland/app wires, so this helper is not in the
# per-frame data path.
cp "$WAYLAND/out/xios-metal-event-broker" "$LIBEXEC/xios-metal-event-broker"
chmod 0755 "$LIBEXEC/xios-metal-event-broker"
xsign "$LIBEXEC/xios-metal-event-broker"
cp "$WAYLAND/com.max.xios.metal-event-broker.plist" \
   "$LAUNCHD/com.max.xios.metal-event-broker.plist"
chmod 0644 "$LAUNCHD/com.max.xios.metal-event-broker.plist"

# 2. wl_shm self-test client (pure software; ad-hoc sign, no entitlements needed).
#    Lets run-iosc.sh paint a test window with no GNOME app installed.
cp "$WAYLAND/out/iosc-client" "$BIN/iosc-client"
chmod 0755 "$BIN/iosc-client"
xsign "$BIN/iosc-client"

# 2b. Input diagnostics and the external-compositor bridge for the unified input
#     socket protocol.
for helper in iosc-input-test ios-inputd; do
  cp "$WAYLAND/out/$helper" "$BIN/$helper"
  chmod 0755 "$BIN/$helper"
  xsign "$BIN/$helper"
done

# 2c. KWin launches its input method from the .desktop named in kwinrc
#     ([Wayland] InputMethod). Ship that entry HERE, next to the binary it points
#     at, rather than having the session script write it at boot: then the bridge
#     is enabled by one persistent setting and does not depend on which
#     xios-session version happens to be installed. run-kde-plasma.sh still
#     points kwinrc at this path (and passes --inputmethod) when it runs.
cat > "$APPS/ios-inputd.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Xios iOS keyboard bridge
Exec=/var/jb/usr/local/bin/ios-inputd --proxy -s /var/jb/tmp/iosc-input.sock
NoDisplay=true
X-KDE-Wayland-VirtualKeyboard=true
EOF
chmod 0644 "$APPS/ios-inputd.desktop"

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
Depends: angle (>= 2.1.0+git20260630.a32d31d+es3-14), libwayland0, libxkbcommon0
Recommends: gnome-console
Section: X11
Priority: optional
Installed-Size: ${INSTKB}
Description: GPU-accelerated Wayland compositor for the Xios desktop
 iosc is a small clean-room Wayland compositor (libwayland-server) for the Xios
 desktop on rootless iOS. It composites Wayland clients on the Apple GPU through
 ANGLE and Metal and hands the finished frame to the Xios app to display, with no
 per-frame copying. GPU completion crosses both process boundaries as Metal shared-event
 fences, so the release path does not serialize every frame through a CPU wait.
 .
 It advertises the protocols modern toolkits expect (xdg-shell windows and popups,
 subsurfaces, viewporter, fractional-scale, and clipboard via wl_data_device),
 stacks multiple windows with focus-on-tap, and routes touch and keyboard from the
 Xios app into the focused window so you can tap and type into a live terminal.
 Since 0.9 it also provides the shell-side protocols (wlr layer-shell,
 foreign-toplevel management and screencopy) that the iosc-shell desktop
 package builds on.
 .
 The package also ships iosc-input-test for direct input-path diagnostics and
 ios-inputd, the input-method bridge for compositors that consume standard
 input-method protocols instead of the in-process Xios input backend. Under KDE,
 where kwin_wayland runs nested and owns the text-input state, KWin launches
 ios-inputd as its zwp_input_method_v1 and it proxies both directions: tapping a
 text field in a Plasma app raises the iOS keyboard, and what you type (including
 emoji and dictation) is committed into the focused field rather than replayed as
 ASCII keystrokes.
 .
 Needs the Xios app installed (the on-screen display front end) and at least one
 Wayland client to be useful. Install the gnome-console package and run run-kgx.sh
 for a GNOME terminal, or run run-iosc.sh for a dependency-free paint self-test.
 The compositor is signed with the GPU entitlement set (a copy is kept under
 /var/jb/usr/local/share/iosc). Built for iPadOS/iOS rootless (palera1n/Dopamine).
EOF

cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/usr/bin:/bin:/usr/sbin:/sbin
plist=/var/jb/Library/LaunchDaemons/com.max.xios.metal-event-broker.plist
chmod 0755 /var/jb/usr/local/libexec/xios-metal-event-broker 2>/dev/null || true
chmod 0644 "$plist" 2>/dev/null || true
chown root:wheel "$plist" 2>/dev/null || true
if command -v launchctl >/dev/null 2>&1; then
  launchctl bootout system "$plist" 2>/dev/null || true
  launchctl bootstrap system "$plist"
fi
exit 0
EOF

cat > "$STAGE/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
plist=/var/jb/Library/LaunchDaemons/com.max.xios.metal-event-broker.plist
if command -v launchctl >/dev/null 2>&1; then
  launchctl bootout system "$plist" 2>/dev/null || true
fi
exit 0
EOF
chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"

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
