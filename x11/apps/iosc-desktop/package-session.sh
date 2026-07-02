#!/bin/bash
# Package the Xios session launcher as an installable rootless-iOS deb.
#
#   bash x11/apps/iosc-desktop/package-session.sh
#
# Ships the "pick a preset -> it launches" flow. The file list (CLI, lib,
# daemon, reused run-*.sh bring-up copies, LaunchDaemon plist) lives in ONE
# place — session-files.sh — shared with install-xios-session.sh, so the deb
# and the scp fast path cannot diverge.
#
# Pure shell — nothing to compile or sign. Output: xios-session_<ver>_iphoneos-arm64.deb
# in x11/linux-build/out and repo/debs.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
OUTDIR="$REPO_ROOT/x11/linux-build/out"
REPODEBS="$REPO_ROOT/repo/debs"
STAGEROOT=/private/tmp/xios-session-deb
STAGE="$STAGEROOT/xios-session"
VER="1.0.4"
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
Suggests: libmutter-14-0, gnome-shell
Section: X11
Priority: optional
Installed-Size: ${INSTKB}
Description: pick-a-desktop session launcher for the Xios stack
 xios-session brings up (and cleanly tears down) the different Xios desktop
 flavors on the iPad from the device itself, instead of SSHing a shell script.
 .
 It provides one on-device command, xios-session, with named presets:
 iosc (the lightweight iosc compositor + wallpaper + panel), mutter (raw Mutter
 --wayland), gnome (gnome-shell --wayland, experimental), app <name> (launch a
 Wayland client such as gnome-console against the running compositor) and stop
 (tear everything down). Each preset reuses the established run-*.sh bring-up
 logic behind a clean name, with one bulletproof teardown so switching sessions
 never leaves a stale compositor or socket behind.
 .
 It also installs xios-sessiond as a compatibility watcher for the request file
 (/var/jb/tmp/xios-request.json). Newer Xios app builds prefer the existing
 ioscd control socket for session picks and fall back to that file while package
 versions may be out of sync.
EOF

# 3. postinst — (re)bootstrap the watcher daemon. No chmod/chown here: modes
#    come from the staged tree (session-files.sh) and ownership from the
#    container's chown -R 0:0; dpkg preserves both.
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/bash
set -e
PLIST=/var/jb/Library/LaunchDaemons/com.max.xios-sessiond.plist
if command -v launchctl >/dev/null 2>&1; then
    launchctl bootout system "$PLIST" 2>/dev/null || true
    launchctl bootstrap system "$PLIST" 2>/dev/null || true
fi
exit 0
EOF
chmod 0755 "$STAGE/DEBIAN/postinst"

# 4. prerm — stop the daemon before removal
cat > "$STAGE/DEBIAN/prerm" <<'EOF'
#!/bin/bash
set -e
PLIST=/var/jb/Library/LaunchDaemons/com.max.xios-sessiond.plist
if command -v launchctl >/dev/null 2>&1; then
    launchctl bootout system "$PLIST" 2>/dev/null || true
fi
exit 0
EOF
chmod 0755 "$STAGE/DEBIAN/prerm"

echo "=== staged tree ==="
find "$STAGE" -type f | sed "s#$STAGE##" | sort
echo "installed=${INSTKB}KB"

# 5. assemble the deb via the container's dpkg-deb (root-owned, zstd like the rest)
docker run --rm --platform linux/arm64 -v "$STAGEROOT":/stage "$IMG" \
  -c "chown -R 0:0 /stage/xios-session && dpkg-deb -Zzstd --build /stage/xios-session /stage/${DEB}"

mkdir -p "$OUTDIR" "$REPODEBS"
cp "$STAGEROOT/${DEB}" "$OUTDIR/${DEB}"
cp "$STAGEROOT/${DEB}" "$REPODEBS/${DEB}"
echo "=== DEB BUILT ==="
ls -la "$OUTDIR/${DEB}" "$REPODEBS/${DEB}"
