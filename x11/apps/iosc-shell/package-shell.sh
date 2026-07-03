#!/bin/bash
# Package the iosc desktop shell clients as an installable iOS deb.
# Host-side: stage the tree and ldid-sign the binaries on macOS, then assemble
# the .deb with the container's dpkg-deb (chowned root:root). Same pipeline as
# wayland/package-iosc.sh.
#
#   bash x11/apps/iosc-shell/package-shell.sh
#
# Inputs (built by build-panel.sh; sign happens here too, so a stale build-time
# signature can never ship):
#   out/ioscbar       slim status bar + Control Center
#   out/ioscdock      floating dock
#   out/ioscoverview  launcher / window switcher
#   out/ioscbg        wallpaper + desktop widgets (wl_shm + ImageIO + cairo)
#   out/icons/        app icon assets, SVG preferred and PNG as fallback
#   run-shell.sh      on-device bring-up script
#   panel-ent.xml     the (non-GPU) client entitlement set
# Output: iosc-shell_<ver>_iphoneos-arm64.deb in x11/linux-build/out and repo/debs.
# Env: IOSC_PACKAGE_SCHEME/THEOS_PACKAGE_SCHEME=rootless|rootful (default rootless).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
_x="$HERE"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"
OUTDIR=/Users/max/Documents/jailbreak/x11/linux-build/out
REPODEBS=/Users/max/Documents/jailbreak/repo/debs
STAGEROOT=/private/tmp/iosc-shell-deb
STAGE="$STAGEROOT/iosc-shell"
VER="0.9.8"
ARCH="iphoneos-arm64"
IMG="procursus-xbuild:bookworm-arm64"
SCHEME="${IOSC_PACKAGE_SCHEME:-${THEOS_PACKAGE_SCHEME:-rootless}}"

case "$SCHEME" in
  rootless)
    DEB_PREFIX=/var/jb
    VERSION_SUFFIX="${IOSC_VERSION_SUFFIX:-}"
    ;;
  rootful)
    DEB_PREFIX=
    VERSION_SUFFIX="${IOSC_VERSION_SUFFIX:-+rootful}"
    ;;
  *)
    echo "ERROR: IOSC_PACKAGE_SCHEME/THEOS_PACKAGE_SCHEME must be rootless or rootful (got $SCHEME)" >&2
    exit 1
    ;;
esac

PKG_VER="${VER}${VERSION_SUFFIX}"
DEB="iosc-shell_${PKG_VER}_${ARCH}.deb"
PREFIX_ROOT="$STAGE$DEB_PREFIX"
BIN="$PREFIX_ROOT/usr/local/bin"
ICONS="$PREFIX_ROOT/usr/share/iosc-shell/icons"
SHARE="$PREFIX_ROOT/usr/local/share/iosc-shell"

for f in out/ioscbar out/ioscdock out/ioscoverview out/ioscbg run-shell.sh panel-ent.xml; do
  [[ -e "$HERE/$f" ]] || { echo "ERROR: $HERE/$f missing (run build-panel.sh first)" >&2; exit 1; }
done

rm -rf "$STAGEROOT"
mkdir -p "$BIN" "$ICONS" "$SHARE" "$STAGE/DEBIAN"

# 1. shell clients -> <prefix>/usr/local/bin, signed with the client entitlement
#    set (wayland socket + .desktop scan + launch; no GPU IOKit classes needed,
#    iosc does the compositing).
for b in ioscbar ioscdock ioscoverview ioscbg; do
  cp "$HERE/out/$b" "$BIN/$b"
  chmod 0755 "$BIN/$b"
  xsign "$BIN/$b" "$HERE/panel-ent.xml" com.apple.private.skip-library-validation
done

if command -v otool >/dev/null; then
  for b in ioscbar ioscdock ioscoverview ioscbg; do
    case "$SCHEME" in
      rootless)
        otool -l "$BIN/$b" | grep -q "/var/jb/usr/lib" || {
          echo "ERROR: $b is not linked for rootless (/var/jb/usr/lib rpath missing)" >&2
          echo "       Rebuild with IOSC_PACKAGE_SCHEME=rootless ./build-panel.sh" >&2
          exit 1
        }
        ;;
      rootful)
        if otool -l "$BIN/$b" | grep -q "/var/jb"; then
          echo "ERROR: $b still contains /var/jb paths; refusing rootful package" >&2
          echo "       Rebuild with IOSC_PACKAGE_SCHEME=rootful ./build-panel.sh" >&2
          exit 1
        fi
        ;;
    esac
  done
else
  echo "WARNING: otool not found; skipping scheme/rpath validation" >&2
fi

# 2. bring-up script (compositor if needed, then wallpaper, bar and dock)
cp "$HERE/run-shell.sh" "$BIN/run-shell.sh"
chmod 0755 "$BIN/run-shell.sh"

# 3. shipped icon set: SVG preferred, PNG retained for raster-only apps.
cp "$HERE"/out/icons/*.svg "$HERE"/out/icons/*.png "$ICONS/" 2>/dev/null || true
chmod 0644 "$ICONS"/*.{svg,png} 2>/dev/null || true

# 4. the entitlement set, for reference / re-signing if ever needed
cp "$HERE/panel-ent.xml" "$SHARE/panel-ent.xml"
chmod 0644 "$SHARE/panel-ent.xml"

INSTKB=$(du -sk "$BIN" "$ICONS" "$SHARE" | awk '{s += $1} END {print s + 0}')

# 5. control. iosc >= 0.9.0 is a hard floor: the shell needs the compositor's
#    zwlr-layer-shell v4, foreign-toplevel v3 and screencopy v1 (0.8.0 has none).
cat > "$STAGE/DEBIAN/control" <<EOF
Package: iosc-shell
Name: iosc desktop shell
Version: ${PKG_VER}
Architecture: ${ARCH}
Maintainer: Max Leiter <maxwell.leiter@gmail.com>
Author: Max Leiter <maxwell.leiter@gmail.com>
Depends: iosc (>= 0.9.0), libwayland0, libcairo2, libpango-1.0-0, libgdk-pixbuf-2.0-0, libglib2.0-0, libharfbuzz0b, libgtkintl, librsvg2-common
Recommends: xios-desktop-theme, x11-fonts-sf, gnome-console
Section: X11
Priority: optional
Installed-Size: ${INSTKB}
Description: lightweight desktop shell for the iosc compositor
 The iosc desktop shell is a small, fast desktop for the Xios stack on jailbroken
 iOS: a slim status bar with battery, time and Control Center; a floating dock
 with app launchers and running-window activation; a full-screen overview with
 app search, an application grid and open window cards over a frosted snapshot
 of the desktop; and a wallpaper client with draggable, persistent system
 widgets for storage, memory, load and uptime. Everything is plain C drawing
 through cairo and pango, so it starts instantly and stays light.
 .
 The shell runs as Wayland layer-shell clients of the iosc compositor. It uses
 no JavaScript and no desktop runtime; the bar, dock, overview and wallpaper are
 small programs that together take a few megabytes of memory.
 .
 Run run-shell.sh on the device to bring up the compositor, wallpaper, status
 bar and dock, then open the Xios app to see the desktop. The dock's grid button
 or the Control Center card opens the overview. Apps are discovered from
 installed .desktop files, with SVG icons for common GNOME applications and PNG
 fallbacks for raster-only packages.
EOF

echo "=== staged tree ==="
find "$STAGE" -type f | sed "s#$STAGE##" | sort
echo "scheme=${SCHEME} prefix=${DEB_PREFIX:-/} installed=${INSTKB}KB"
echo "=== ioscbar entitlements (client set, no GPU classes) ==="
ldid -e "$BIN/ioscbar" | grep -E "no-container|get-task-allow|absolute-path" | sed 's/^/   /' || true

# 6. assemble the deb (root-owned, zstd) via xmkdeb — builds in the container on a
#    macOS host, or directly when already running as root inside one.
built="$(xmkdeb "$STAGE" "$OUTDIR")"
cp "$built" "$REPODEBS/${DEB}"
echo "=== DEB BUILT ==="
ls -la "$OUTDIR/${DEB}" "$REPODEBS/${DEB}"
