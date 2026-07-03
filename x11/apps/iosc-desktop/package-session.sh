#!/bin/bash
# Package the Xios session launcher as an installable rootless-iOS deb.
#
#   bash x11/apps/iosc-desktop/package-session.sh
#
# Ships the "pick a preset -> it launches" flow. The file list (CLI, lib,
# reused run-*.sh bring-up copies) lives in ONE
# place — session-files.sh — shared with install-xios-session.sh, so the deb
# and the scp fast path cannot diverge.
#
# Pure shell — nothing to compile or sign. Output: xios-session_<ver>_iphoneos-arm64.deb
# in x11/linux-build/out and repo/debs.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
_x="$HERE"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
OUTDIR="$REPO_ROOT/x11/linux-build/out"
REPODEBS="$REPO_ROOT/repo/debs"
STAGEROOT=/private/tmp/xios-session-deb
STAGE="$STAGEROOT/xios-session"
VER="1.0.10"
ARCH="iphoneos-arm64"
DEB="xios-session_${VER}_${ARCH}.deb"
IMG="procursus-xbuild:bookworm-arm64"

# 1. stage the ship manifest (single source of truth: session-files.sh)
. "$HERE/session-files.sh"
rm -rf "$STAGEROOT"
mkdir -p "$STAGE/DEBIAN"
stage_session_files "$STAGE/var/jb"

INSTKB=$(du -sk "$STAGE/var/jb" | cut -f1)

# 2. control
cat > "$STAGE/DEBIAN/control" <<EOF
Package: xios-session
Name: Xios session launcher
Version: ${VER}
Architecture: ${ARCH}
Maintainer: Max Leiter <maxwell.leiter@gmail.com>
Author: Max Leiter <maxwell.leiter@gmail.com>
Depends: iosc (>= 0.9.0)
Recommends: iosc-shell, xios
Suggests: libmutter-14-0, gnome-shell, kwin, plasma-workspace
Section: X11
Priority: optional
Installed-Size: ${INSTKB}
Description: pick-a-desktop session launcher for the Xios stack
 xios-session brings up (and cleanly tears down) the different Xios desktop
 flavors on the iPad from the device itself, instead of SSHing a shell script.
 .
 It provides one on-device command, xios-session, with named presets:
 iosc (the lightweight iosc compositor + wallpaper + panel), mutter (raw Mutter
 --wayland), gnome (gnome-shell --wayland, experimental), kde (KWin +
 plasmashell nested on iosc, experimental), app <name> (launch a Wayland client
 such as gnome-console against the running compositor) and stop (tear everything
 down). Each preset reuses the established run-*.sh bring-up
 logic behind a clean name, with one bulletproof teardown so switching sessions
 never leaves a stale compositor or socket behind.
 .
 In-app session picks use the ioscd control socket; this package does not ship
 a request-file watcher or legacy fallback path.
EOF

echo "=== staged tree ==="
find "$STAGE" -type f | sed "s#$STAGE##" | sort
echo "installed=${INSTKB}KB"

# 3. assemble the deb (root-owned, zstd) via xmkdeb — builds in the container on a
#    macOS host, or directly when already running as root inside one.
mkdir -p "$OUTDIR" "$REPODEBS"
built="$(xmkdeb "$STAGE" "$OUTDIR")"
cp "$built" "$REPODEBS/${DEB}"
echo "=== DEB BUILT ==="
ls -la "$OUTDIR/${DEB}" "$REPODEBS/${DEB}"
