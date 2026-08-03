#!/usr/bin/env bash
# Package OpenGFX as OpenTTD's base graphics set.
#
#   linux-build/build-opengfx-package.sh [target-id]
#
# OpenTTD ships no graphics of its own. Without a base set the game starts, maps
# a window, and then stops at a "Missing graphics" bootstrap that offers to
# download one over the network. That bootstrap is the only thing standing
# between the current OpenTTD port and a playable main menu, and an on-device
# download is not reproducible evidence. This packages the same free set the
# bootstrap would fetch so the game has graphics from a normal apt install.
#
# OpenGFX is GPL v2 (see the bundled license.txt) and is the base set the
# OpenTTD project itself distributes for this purpose.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
X11DIR="$(cd "$HERE/.." && pwd)"
. "$HERE/target-lib.sh"
_x="$HERE"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"

OPENGFX_VERSION="${OPENGFX_VERSION:-7.1}"
# Pinned so a silently re-rolled upstream archive fails loudly instead of
# shipping unreviewed content into a package.
OPENGFX_SHA256="928fcf34efd0719a3560cbab6821d71ce686b6315e8825360fba87a7a94d7846"
DEB_VERSION="${OPENGFX_VERSION}+ios1"

TARGET="${XIOS_TARGET:-rootless-1900}"
[ "${1:-}" ] && TARGET="$1"
xios_load_target "$TARGET"

STAGEROOT="$X11DIR/linux-build/stage/$XIOS_TARGET_ID/openttd-opengfx"
STAGE="$STAGEROOT/root"
OUTDIR="$X11DIR/linux-build/out"
if [ "$XIOS_TARGET_ID" != "rootless-1900" ]; then
  OUTDIR="$OUTDIR/targets/$XIOS_TARGET_ID"
fi
WORK="$STAGEROOT/work"

rm -rf "$STAGEROOT"
mkdir -p "$STAGE/DEBIAN" "$WORK"

ARCHIVE="$WORK/opengfx-$OPENGFX_VERSION-all.zip"
echo "==> fetching OpenGFX $OPENGFX_VERSION"
curl -fsSL -o "$ARCHIVE" \
  "https://cdn.openttd.org/opengfx-releases/$OPENGFX_VERSION/opengfx-$OPENGFX_VERSION-all.zip"

echo "==> verifying pinned checksum"
actual="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
if [ "$actual" != "$OPENGFX_SHA256" ]; then
  echo "ERROR: OpenGFX checksum mismatch" >&2
  echo "  expected $OPENGFX_SHA256" >&2
  echo "  actual   $actual" >&2
  exit 1
fi

# The published zip wraps a tar, which in turn holds the versioned directory.
unzip -q -o "$ARCHIVE" -d "$WORK"
tar -xf "$WORK/opengfx-$OPENGFX_VERSION.tar" -C "$WORK"
SRC="$WORK/opengfx-$OPENGFX_VERSION"
[ -f "$SRC/opengfx.obg" ] || { echo "ERROR: no opengfx.obg in $SRC" >&2; exit 1; }

# OpenTTD scans subdirectories of its baseset directory, so keeping the set in
# its own directory leaves the openttd package's own files untouched and makes
# every file here owned by this package.
BASESET="$STAGE$XIOS_PACKAGE_PATH_PREFIX/usr/share/games/openttd/baseset/opengfx"
DOCDIR="$STAGE$XIOS_PACKAGE_PATH_PREFIX/usr/share/doc/openttd-opengfx"
mkdir -p "$BASESET" "$DOCDIR"
cp -a "$SRC"/*.grf "$SRC"/opengfx.obg "$BASESET/"
cp -a "$SRC/license.txt" "$SRC/readme.txt" "$SRC/changelog.txt" "$DOCDIR/"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: openttd-opengfx
Name: OpenGFX base graphics for OpenTTD
Version: $DEB_VERSION
Architecture: $XIOS_DEB_ARCH
Maintainer: Max Leiter <maxwell.leiter@gmail.com>
Author: OpenTTD project
Depends: openttd
Section: Games
Priority: optional
Description: The free base graphics set OpenTTD needs to start
 OpenTTD cannot run without a base graphics set, and ships none. On a fresh
 install the game reaches its window and then stops at a bootstrap prompting to
 download one. This package installs OpenGFX $OPENGFX_VERSION into the shared
 baseset directory so the game goes straight to its main menu with no network
 access and no first-run prompt.
 .
 OpenGFX is GPL v2; see /var/jb/usr/share/doc/openttd-opengfx/license.txt.
EOF

find "$STAGE" -type d -exec chmod 0755 {} +
find "$STAGE" -type f -exec chmod 0644 {} +

python3 "$X11DIR/linux-build/tools/check-target-package.py" "$STAGE" "$XIOS_TARGET_ID"

mkdir -p "$OUTDIR"
built="$(xmkdeb "$STAGE" "$OUTDIR")"
echo "==> built $built"
