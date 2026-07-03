#!/bin/bash
# Package the Xios session launcher as an installable iOS deb.
#
#   bash x11/apps/iosc-desktop/package-session.sh [target-id] [--stage-only]
#
# Ships the "pick a preset -> it launches" flow. The file list (CLI, lib,
# reused run-*.sh bring-up copies) lives in ONE
# place — session-files.sh — shared with install-xios-session.sh, so the deb
# and the scp fast path cannot diverge.
#
# Pure shell — nothing to compile or sign. Rootless output also copies to repo/debs;
# non-rootless outputs stay under x11/linux-build/out/targets/<target-id>/.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
_x="$HERE"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
X11DIR="$REPO_ROOT/x11"
. "$X11DIR/linux-build/target-lib.sh"

TARGET="${XIOS_TARGET:-rootless-1900}"
STAGE_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stage-only) STAGE_ONLY=1 ;;
    -h|--help)
      echo "usage: $0 [target-id] [--stage-only]" >&2
      exit 0
      ;;
    *) TARGET="$1" ;;
  esac
  shift
done

xios_load_target "$TARGET"

OUTDIR="$X11DIR/linux-build/out"
if [ "$XIOS_TARGET_ID" != "rootless-1900" ]; then
  OUTDIR="$OUTDIR/targets/$XIOS_TARGET_ID"
fi
REPODEBS="$REPO_ROOT/repo/debs"
STAGEROOT="/private/tmp/xios-session-deb/$XIOS_TARGET_ID"
STAGE="$STAGEROOT/xios-session"
VER="1.0.17"
ARCH="$XIOS_DEB_ARCH"
DEB="xios-session_${VER}_${ARCH}.deb"

# 1. stage the ship manifest (single source of truth: session-files.sh)
. "$HERE/session-files.sh"
rm -rf "$STAGEROOT"
mkdir -p "$STAGE/DEBIAN"
PAYLOAD_ROOT="$STAGE$XIOS_PACKAGE_PATH_PREFIX"
[ -n "$PAYLOAD_ROOT" ] || PAYLOAD_ROOT="$STAGE"
stage_session_files "$PAYLOAD_ROOT"

INSTKB=$(du -sk "$PAYLOAD_ROOT" | cut -f1)

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
Suggests: libmutter-14-0, gnome-shell, kwin, plasma-workspace, plasma-desktop, plasma-nano, plasma-mobile
Replaces: iosc-shell (<= 0.9.9)
Section: X11
Priority: optional
Installed-Size: ${INSTKB}
Description: pick-a-desktop session launcher for the Xios stack
 xios-session brings up (and cleanly tears down) the different Xios desktop
 flavors on the iPad from the device itself, instead of SSHing a shell script.
 .
 Build target: ${XIOS_TARGET_ID} (${XIOS_REPO_PROFILE}, ${XIOS_MEMO_TARGET}, CFVER ${XIOS_MEMO_CFVER}).
 .
 It provides one on-device command, xios-session, with named presets:
 iosc (the lightweight iosc compositor + wallpaper + panel), mutter (raw Mutter
 --wayland), gnome (gnome-shell --wayland, experimental), kde (KWin + desktop
 plasmashell nested on iosc, experimental), kde-nano (KWin + Plasma Nano shell),
 kde-mobile (KWin + Plasma Mobile shell), app <name> (launch a Wayland client
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
if [ "$STAGE_ONLY" = 1 ]; then
  exit 0
fi

# 3. assemble the deb (root-owned, zstd) via xmkdeb — builds in the container on a
#    macOS host, or directly when already running as root inside one.
mkdir -p "$OUTDIR"
built="$(xmkdeb "$STAGE" "$OUTDIR")"
if [ "$XIOS_TARGET_ID" = "rootless-1900" ]; then
  mkdir -p "$REPODEBS"
  cp "$built" "$REPODEBS/${DEB}"
fi
echo "=== DEB BUILT ==="
ls -la "$OUTDIR/${DEB}"
if [ "$XIOS_TARGET_ID" = "rootless-1900" ]; then
  ls -la "$REPODEBS/${DEB}"
else
  echo "target artifact kept out of repo/debs: $built"
fi
