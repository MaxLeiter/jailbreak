#!/bin/bash
# Package the iosc desktop shell clients as an installable rootless-iOS deb.
# Host-side: stage the tree and ldid-sign the binaries on macOS, then assemble
# the .deb with the container's dpkg-deb (chowned root:root). Same pipeline as
# wayland/package-iosc.sh.
#
#   bash x11/apps/iosc-shell/package-shell.sh
#
# Inputs (built by build-panel.sh; sign happens here too, so a stale build-time
# signature can never ship):
#   out/ioscpanel     panel + quick settings (cairo/pangocairo layer-shell client)
#   out/ioscoverview  launcher / window switcher
#   out/ioscbg        wallpaper (wl_shm + ImageIO)
#   out/icons/        pre-rasterised app icon PNGs (gen-shell-icons.sh)
#   run-shell.sh      on-device bring-up script
#   panel-ent.xml     the (non-GPU) client entitlement set
# Output: iosc-shell_<ver>_iphoneos-arm64.deb in x11/linux-build/out and repo/debs.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUTDIR=/Users/max/Documents/jailbreak/x11/linux-build/out
REPODEBS=/Users/max/Documents/jailbreak/repo/debs
STAGEROOT=/private/tmp/iosc-shell-deb
STAGE="$STAGEROOT/iosc-shell"
VER="0.9.3"
ARCH="iphoneos-arm64"
DEB="iosc-shell_${VER}_${ARCH}.deb"
IMG="procursus-xbuild:bookworm-arm64"

BIN="$STAGE/var/jb/usr/local/bin"
ICONS="$STAGE/var/jb/usr/share/iosc-shell/icons"   # PI_ASSETS_DEFAULT (panel-icons.h)
SHARE="$STAGE/var/jb/usr/local/share/iosc-shell"

for f in out/ioscpanel out/ioscoverview out/ioscbg run-shell.sh panel-ent.xml; do
  [[ -e "$HERE/$f" ]] || { echo "ERROR: $HERE/$f missing (run build-panel.sh first)" >&2; exit 1; }
done

rm -rf "$STAGEROOT"
mkdir -p "$BIN" "$ICONS" "$SHARE" "$STAGE/DEBIAN"

# 1. shell clients -> /var/jb/usr/local/bin, signed with the client entitlement
#    set (wayland socket + .desktop scan + launch; no GPU IOKit classes needed,
#    iosc does the compositing).
for b in ioscpanel ioscoverview ioscbg; do
  cp "$HERE/out/$b" "$BIN/$b"
  chmod 0755 "$BIN/$b"
  ldid -S"$HERE/panel-ent.xml" "$BIN/$b"
done

# 2. bring-up script (compositor if needed, then wallpaper, then panel)
cp "$HERE/run-shell.sh" "$BIN/run-shell.sh"
chmod 0755 "$BIN/run-shell.sh"

# 3. pre-rasterised icon set (no SVG loader on device; see panel-icons.h)
cp "$HERE"/out/icons/*.png "$ICONS/" 2>/dev/null || true
chmod 0644 "$ICONS"/*.png 2>/dev/null || true

# 4. the entitlement set, for reference / re-signing if ever needed
cp "$HERE/panel-ent.xml" "$SHARE/panel-ent.xml"
chmod 0644 "$SHARE/panel-ent.xml"

INSTKB=$(du -sk "$STAGE/var/jb" | cut -f1)

# 5. control. iosc >= 0.9.0 is a hard floor: the shell needs the compositor's
#    zwlr-layer-shell v4, foreign-toplevel v3 and screencopy v1 (0.8.0 has none).
cat > "$STAGE/DEBIAN/control" <<EOF
Package: iosc-shell
Name: iosc desktop shell
Version: ${VER}
Architecture: ${ARCH}
Maintainer: Max Leiter <maxwell.leiter@gmail.com>
Author: Max Leiter <maxwell.leiter@gmail.com>
Depends: iosc (>= 0.9.0), libwayland0, libcairo2, libpango-1.0-0, libglib2.0-0, libharfbuzz0b, libgtkintl
Recommends: xios-desktop-theme, x11-fonts-sf, gnome-console
Section: X11
Priority: optional
Installed-Size: ${INSTKB}
Description: lightweight desktop shell for the iosc compositor
 The iosc desktop shell is a small, fast desktop for the Xios stack on rootless
 iOS: a top panel with app launchers, a window taskbar and a battery, date and
 time status cluster; a quick settings card; a full-screen overview with app
 search, an application grid and open window cards over a frosted snapshot of
 the desktop; and a wallpaper client. Everything is plain C drawing through
 cairo and pango, so it starts instantly and stays light.
 .
 The shell runs as Wayland layer-shell clients of the iosc compositor. It uses
 no JavaScript and no desktop runtime; the panel, overview and wallpaper are
 three small programs that together take a few megabytes of memory.
 .
 Run run-shell.sh on the device to bring up the compositor, wallpaper and
 panel, then open the Xios app to see the desktop. The panel's grid button or
 the quick settings card opens the overview. Apps are discovered from installed
 .desktop files, with pre-rendered icons for common GNOME applications.
EOF

echo "=== staged tree ==="
find "$STAGE" -type f | sed "s#$STAGE##" | sort
echo "installed=${INSTKB}KB"
echo "=== ioscpanel entitlements (client set, no GPU classes) ==="
ldid -e "$BIN/ioscpanel" | grep -E "no-container|get-task-allow|absolute-path" | sed 's/^/   /' || true

# 6. assemble the deb via the container's dpkg-deb (root-owned, zstd like the rest)
docker run --rm --platform linux/arm64 -v "$STAGEROOT":/stage "$IMG" \
  -c "chown -R 0:0 /stage/iosc-shell && dpkg-deb -Zzstd --build /stage/iosc-shell /stage/${DEB}"

cp "$STAGEROOT/${DEB}" "$OUTDIR/${DEB}"
cp "$STAGEROOT/${DEB}" "$REPODEBS/${DEB}"
echo "=== DEB BUILT ==="
ls -la "$OUTDIR/${DEB}" "$REPODEBS/${DEB}"
