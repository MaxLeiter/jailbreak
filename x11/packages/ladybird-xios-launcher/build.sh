#!/usr/bin/env bash
set -euo pipefail

PKGDIR="$(cd "$(dirname "$0")" && pwd)"
_x="$PKGDIR"
while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do
  _x="$(dirname "$_x")"
done
. "$_x/lib/xlib.sh"

X11DIR="$(cd "$PKGDIR/../.." && pwd)"
OUT="$X11DIR/linux-build/out"
STAGEROOT=/private/tmp/ladybird-xios-launcher-stage
STAGE="$STAGEROOT/ladybird-xios-launcher"

rm -rf "$STAGEROOT"
mkdir -p "$STAGE"
cp -a "$PKGDIR/DEBIAN" "$PKGDIR/var" "$STAGE/"

ICON_SRC="$X11DIR/packages/ladybird-app/Resources/AppIcon.png"
ICON_DIR="$STAGE/var/jb/usr/share/icons/hicolor/256x256/apps"
mkdir -p "$ICON_DIR"
install -m 0644 "$ICON_SRC" "$ICON_DIR/ladybird.png"

find "$STAGE" -type d -exec chmod 0755 {} +
find "$STAGE" -type f -exec chmod 0644 {} +
chmod 0755 "$STAGE/DEBIAN/postinst"

built="$(xmkdeb "$STAGE" "$OUT")"
echo "==> built $built"
