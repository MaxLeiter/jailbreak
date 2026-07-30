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
_xt="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ "$_xt" != / ] && [ ! -f "$_xt/linux-build/target-lib.sh" ]; do _xt="$(dirname "$_xt")"; done
. "$_xt/linux-build/target-lib.sh"
xios_load_target_arg "${1:-}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_x="$HERE"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"

WAYLAND="$HERE"
# Binaries come from the target's own output dir; build-iosc.sh writes rootless
# to wayland/out and every other target to wayland/out/targets/<id>.
BINDIR="$HERE/out"
[ "$XIOS_TARGET_ID" = "rootless-1900" ] || BINDIR="$BINDIR/targets/$XIOS_TARGET_ID"
[ -d "$BINDIR" ] || { echo "ERROR: no iosc build for $XIOS_TARGET_ID at $BINDIR" >&2
  echo "       Build it first: XIOS_TARGET=$XIOS_TARGET_ID bash wayland/build-iosc.sh" >&2; exit 1; }
OUTDIR="$XLIB_ROOT/linux-build/out"
REPODEBS="$(cd "$XLIB_ROOT/.." && pwd)/repo/debs"
if [ "$XIOS_TARGET_ID" != "rootless-1900" ]; then
  OUTDIR="$OUTDIR/targets/$XIOS_TARGET_ID"
  # repo/debs is the published rootless repo; other profiles do not go there.
  REPODEBS=""
fi
mkdir -p "$OUTDIR"
STAGEROOT=/private/tmp/iosc-deb
STAGE="$STAGEROOT/iosc"
VER="0.9.36"
ARCH="$XIOS_DEB_ARCH"
DEB="iosc_${VER}_${ARCH}.deb"

BIN="$STAGE$XIOS_PREFIX/usr/local/bin"
SHARE="$STAGE$XIOS_PREFIX/usr/local/share/iosc"
LIB="$STAGE$XIOS_PREFIX/usr/local/lib"
LIBEXEC="$STAGE$XIOS_PREFIX/usr/local/libexec"
LAUNCHD="$STAGE$XIOS_PREFIX/Library/LaunchDaemons"
APPS="$STAGE$XIOS_PREFIX/usr/share/applications"

# The plist and the entitlement file are committed with rootless paths. Render
# them for the target rather than copying: the plist's ProgramArguments and log
# paths, and the entitlement's filesystem exception, all have to match where the
# package actually installs. $XIOS_RUNTIME_TMP is /var/jb/tmp or /var/tmp.
render_target_file() {
  sed -e "s|/var/jb/tmp|$XIOS_RUNTIME_TMP|g" \
      -e "s|/var/jb/|$XIOS_PREFIX/|g" \
      -e "s|<string>/var/jb</string>|<string>${XIOS_PREFIX:-/}</string>|g" "$1" > "$2"
}

rm -rf "$STAGEROOT"
mkdir -p "$BIN" "$SHARE" "$LIB" "$LIBEXEC" "$LAUNCHD" "$APPS" "$STAGE/DEBIAN"

# 1. compositor binary -> /var/jb/usr/local/bin, signed with the GPU entitlement
#    set (AGX/IOGPU/IOSurface IOKit + task_for_pid, NO no-container). Without these
#    iosc cannot reach the GPU and fails closed; see iosc-gl-ent.xml.
cp "$BINDIR/iosc" "$BIN/iosc"
chmod 0755 "$BIN/iosc"
ENT_RENDERED="$STAGEROOT/iosc-gl-ent.xml"
mkdir -p "$STAGEROOT"
render_target_file "$WAYLAND/iosc-gl-ent.xml" "$ENT_RENDERED"
xsign "$BIN/iosc" "$ENT_RENDERED" \
  platform-application com.apple.private.skip-library-validation task_for_pid-allow \
  AGXDeviceUserClient IOGPUDeviceUserClient IOSurfaceRootUserClient

# One-time MTLSharedEventHandle transport. launchd owns the named Mach service;
# frame values continue on the Wayland/app wires, so this helper is not in the
# per-frame data path.
cp "$BINDIR/xios-metal-event-broker" "$LIBEXEC/xios-metal-event-broker"
chmod 0755 "$LIBEXEC/xios-metal-event-broker"
xsign "$LIBEXEC/xios-metal-event-broker"
render_target_file "$WAYLAND/com.max.xios.metal-event-broker.plist" \
   "$LAUNCHD/com.max.xios.metal-event-broker.plist"
chmod 0644 "$LAUNCHD/com.max.xios.metal-event-broker.plist"

# 2. wl_shm self-test client (pure software; ad-hoc sign, no entitlements needed).
#    Lets run-iosc.sh paint a test window with no GNOME app installed.
cp "$BINDIR/iosc-client" "$BIN/iosc-client"
chmod 0755 "$BIN/iosc-client"
xsign "$BIN/iosc-client"

# 2b. Input diagnostics and the compatibility bridge for compositors that consume
#     virtual-keyboard/input-method protocols instead of linking libxios_glue.
for helper in iosc-input-test ios-inputd; do
  cp "$BINDIR/$helper" "$BIN/$helper"
  chmod 0755 "$BIN/$helper"
  xsign "$BIN/$helper"
done

# 2c. KWin launches its input method from the desktop entry named by kwinrc.
# Keep that entry in the package that owns ios-inputd so the setting cannot
# silently depend on a particular xios-session package revision.
cat > "$APPS/ios-inputd.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Xios iOS keyboard bridge
Exec=$XIOS_PREFIX/usr/local/bin/ios-inputd --proxy -s $XIOS_RUNTIME_TMP/iosc-input.sock
NoDisplay=true
X-KDE-Wayland-VirtualKeyboard=true
EOF
chmod 0644 "$APPS/ios-inputd.desktop"

# 3. orchestration scripts (run on-device as root; reference $BIN/iosc by abs path)
cp "$WAYLAND/run-iosc.sh" "$BIN/run-iosc.sh"
cp "$WAYLAND/run-kgx.sh"  "$BIN/run-kgx.sh"
chmod 0755 "$BIN/run-iosc.sh" "$BIN/run-kgx.sh"

# 4. the GPU entitlement set, for reference / re-signing the binary if ever needed
render_target_file "$WAYLAND/iosc-gl-ent.xml" "$SHARE/iosc-gl-ent.xml"
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
if [ -f "$BINDIR/libiosc_egl.dylib" ]; then
  cp "$BINDIR/libiosc_egl.dylib" "$LIB/libiosc_egl.dylib"
  chmod 0755 "$LIB/libiosc_egl.dylib"
  xsign "$LIB/libiosc_egl.dylib"
else
  echo "WARN: libiosc_egl.dylib not found at $WAYLAND/out — build-iosc.sh not run?"
fi

INSTKB=$(du -sk "$STAGE${XIOS_PREFIX:-/usr}" | cut -f1)

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
 ios-inputd for external Wayland compositors that use standard virtual-keyboard
 and input-method protocols instead of the in-process Xios input backend.
 .
 Needs the Xios app installed (the on-screen display front end) and at least one
 Wayland client to be useful. Install the gnome-console package and run run-kgx.sh
 for a GNOME terminal, or run run-iosc.sh for a dependency-free paint self-test.
 The compositor is signed with the GPU entitlement set (a copy is kept under
 $XIOS_PREFIX/usr/local/share/iosc). Built for iPadOS/iOS rootless (palera1n/Dopamine).
EOF

# The prefix is baked in as a variable by an expanding header, then the body
# stays single-quoted so its own runtime variables ($plist) survive to the
# device. Unquoting the whole heredoc would expand those at build time.
cat > "$STAGE/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
PREFIX=$XIOS_PREFIX
EOF
cat >> "$STAGE/DEBIAN/postinst" <<'EOF'
PATH=$PREFIX/usr/bin:$PREFIX/usr/sbin:/usr/bin:/bin:/usr/sbin:/sbin
plist=$PREFIX/Library/LaunchDaemons/com.max.xios.metal-event-broker.plist
chmod 0755 $PREFIX/usr/local/libexec/xios-metal-event-broker 2>/dev/null || true
chmod 0644 "$plist" 2>/dev/null || true
chown root:wheel "$plist" 2>/dev/null || true
if command -v launchctl >/dev/null 2>&1; then
  launchctl bootout system "$plist" 2>/dev/null || true
  launchctl bootstrap system "$plist"
fi
exit 0
EOF

cat > "$STAGE/DEBIAN/prerm" <<EOF
#!/bin/sh
set -e
PREFIX=$XIOS_PREFIX
EOF
cat >> "$STAGE/DEBIAN/prerm" <<'EOF'
plist=$PREFIX/Library/LaunchDaemons/com.max.xios.metal-event-broker.plist
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
echo "=== DEB BUILT ==="
if [ -n "$REPODEBS" ]; then
  cp "$built" "$REPODEBS/${DEB}"
  ls -la "$OUTDIR/${DEB}" "$REPODEBS/${DEB}"
else
  # Non-rootless profiles stay out of repo/debs: that tree is the published
  # rootless repo, and make-repo.py refuses a foreign payload there anyway.
  ls -la "$OUTDIR/${DEB}"
fi
