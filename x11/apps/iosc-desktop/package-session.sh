#!/bin/bash
# Package the Xios session launcher as an installable rootless-iOS deb.
#
#   bash x11/apps/iosc-desktop/package-session.sh
#
# Ships the "pick a preset -> it launches" flow:
#   /var/jb/usr/local/bin/xios-session                 the on-device CLI (in PATH)
#   /var/jb/libexec/xios-session/xios-session-lib.sh   shared teardown + presets
#   /var/jb/libexec/xios-session/xios-sessiond         request-file watcher daemon
#   /var/jb/libexec/xios-session/run-shell.sh          iosc bring-up   (reused copy)
#   /var/jb/libexec/xios-session/run-mutter.sh         mutter bring-up (reused copy)
#   /var/jb/libexec/xios-session/run-gnome-shell.sh    gnome bring-up  (reused copy)
#   /var/jb/Library/LaunchDaemons/com.max.xios-sessiond.plist
#
# Pure shell — nothing to compile or sign. Output: xios-session_<ver>_iphoneos-arm64.deb
# in x11/linux-build/out and repo/debs.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
WAYLAND="$REPO_ROOT/x11/wayland"
SHELLDIR="$REPO_ROOT/x11/apps/iosc-shell"
OUTDIR="$REPO_ROOT/x11/linux-build/out"
REPODEBS="$REPO_ROOT/repo/debs"
STAGEROOT=/private/tmp/xios-session-deb
STAGE="$STAGEROOT/xios-session"
VER="1.0.2"
ARCH="iphoneos-arm64"
DEB="xios-session_${VER}_${ARCH}.deb"
IMG="procursus-xbuild:bookworm-arm64"

BIN="$STAGE/var/jb/usr/local/bin"
LIBEXEC="$STAGE/var/jb/libexec/xios-session"
LD="$STAGE/var/jb/Library/LaunchDaemons"

rm -rf "$STAGEROOT"
mkdir -p "$BIN" "$LIBEXEC" "$LD" "$STAGE/DEBIAN"

# 1. CLI (in PATH)
cp "$HERE/xios-session" "$BIN/xios-session"
chmod 0755 "$BIN/xios-session"

# 2. library + daemon
cp "$HERE/xios-session-lib.sh" "$LIBEXEC/xios-session-lib.sh"
cp "$HERE/xios-sessiond"       "$LIBEXEC/xios-sessiond"
chmod 0644 "$LIBEXEC/xios-session-lib.sh"
chmod 0755 "$LIBEXEC/xios-sessiond"

# 3. reused bring-up scripts (call the REAL run-*.sh — see xios-session-lib.sh).
#    Copies live in our libexec so the presets resolve even if iosc-shell / the
#    dev tree aren't the ones that installed them.
cp "$SHELLDIR/run-shell.sh"        "$LIBEXEC/run-shell.sh"
cp "$WAYLAND/run-mutter.sh"        "$LIBEXEC/run-mutter.sh"
cp "$WAYLAND/run-gnome-shell.sh"   "$LIBEXEC/run-gnome-shell.sh"
chmod 0755 "$LIBEXEC/run-shell.sh" "$LIBEXEC/run-mutter.sh" "$LIBEXEC/run-gnome-shell.sh"

# 4. LaunchDaemon
cp "$HERE/com.max.xios-sessiond.plist" "$LD/com.max.xios-sessiond.plist"
chmod 0644 "$LD/com.max.xios-sessiond.plist"

INSTKB=$(du -sk "$STAGE/var/jb" | cut -f1)

# 5. control
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
 It also installs xios-sessiond, a small root daemon that watches the same
 request file the Xios app already writes (/var/jb/tmp/xios-request.json) for a
 {"action":"session","preset":...} pick, so an in-app session picker can bring up
 a flavor with no terminal. This is the first concrete step of the "install one
 xios meta-package, then pick your flavor" distribution.
EOF

# 6. postinst — (re)bootstrap the watcher daemon
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/bash
set -e
PLIST=/var/jb/Library/LaunchDaemons/com.max.xios-sessiond.plist
chown root:wheel "$PLIST" 2>/dev/null || true
chmod 0644 "$PLIST" 2>/dev/null || true
chmod 0755 /var/jb/usr/local/bin/xios-session /var/jb/libexec/xios-session/xios-sessiond \
           /var/jb/libexec/xios-session/run-*.sh 2>/dev/null || true
if command -v launchctl >/dev/null 2>&1; then
    launchctl bootout system "$PLIST" 2>/dev/null || true
    launchctl bootstrap system "$PLIST" 2>/dev/null || true
fi
exit 0
EOF
chmod 0755 "$STAGE/DEBIAN/postinst"

# 7. prerm — stop the daemon before removal
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

# 8. assemble the deb via the container's dpkg-deb (root-owned, zstd like the rest)
docker run --rm --platform linux/arm64 -v "$STAGEROOT":/stage "$IMG" \
  -c "chown -R 0:0 /stage/xios-session && dpkg-deb -Zzstd --build /stage/xios-session /stage/${DEB}"

mkdir -p "$OUTDIR" "$REPODEBS"
cp "$STAGEROOT/${DEB}" "$OUTDIR/${DEB}"
cp "$STAGEROOT/${DEB}" "$REPODEBS/${DEB}"
echo "=== DEB BUILT ==="
ls -la "$OUTDIR/${DEB}" "$REPODEBS/${DEB}"
