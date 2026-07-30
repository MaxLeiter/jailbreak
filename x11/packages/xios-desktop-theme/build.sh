#!/usr/bin/env bash
# Build the xios-desktop-theme .deb.
#
# Runs everything in a Debian container so the package is reproducible on any
# host with Docker: it generates the wallpaper, assembles the rootless /var/jb
# tree with root:root ownership, and packs a zstd .deb next to the siblings.
#
# The Adwaita icon/cursor data is NOT bundled here — it lives in the standalone
# adwaita-icon-theme package (Depends), the single owner of icons/Adwaita/*, so
# the two never collide. This package ships only the look layer (control,
# postinst, the default cursor-theme redirect, the gschema override, the
# wallpaper, and this script).
set -euo pipefail
_xt="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ "$_xt" != / ] && [ ! -f "$_xt/linux-build/target-lib.sh" ]; do _xt="$(dirname "$_xt")"; done
. "$_xt/linux-build/target-lib.sh"
xios_load_target "${XIOS_TARGET:-rootless-1900}"

PKGDIR="$(cd "$(dirname "$0")" && pwd)"
OUTDIR="$(cd "$PKGDIR/.." && pwd)"          # x11/packages
VERSION="$(awk -F': ' '/^Version:/{print $2}' "$PKGDIR/DEBIAN/control")"
DEB="xios-desktop-theme_${VERSION}_iphoneos-arm64.deb"
IMAGE="debian:bookworm-slim"

docker run --rm -v "$OUTDIR":/work -w /work "$IMAGE" bash -euo pipefail -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null
  apt-get install -y -qq --no-install-recommends python3-pil python3-numpy ca-certificates >/dev/null

  TREE=/work/xios-desktop-theme
  STAGE=/tmp/stage
  rm -rf "$STAGE"; mkdir -p "$STAGE"

  # Wallpaper first, into the committed tree, so it persists on the host.
  mkdir -p "$TREE$XIOS_PREFIX/usr/share/backgrounds/xios"
  python3 "$TREE/tools/make-wallpaper.py" \
    "$TREE$XIOS_PREFIX/usr/share/backgrounds/xios/xios-default.jpg"
  python3 "$TREE/tools/make-wallpaper.py" \
    "$TREE$XIOS_PREFIX/usr/share/backgrounds/xios/xios-default.png"

  # Copy the committed tree (DEBIAN + var) into the staging root.
  cp -a "$TREE/DEBIAN" "$STAGE/"
  cp -a "$TREE/var" "$STAGE/"

  # NOTE: the Adwaita icon/cursor tree is NOT bundled here any more — it is owned
  # by the standalone adwaita-icon-theme package (this package Depends on it), so
  # the two never collide on /var/jb/usr/share/icons/Adwaita/*. This package now
  # only ships the look layer: the wallpaper, the gsettings override, and the
  # default/ cursor-theme redirect (Inherits=Adwaita, resolved via the dependency).

  # Drop machine-generated caches (rebuilt by the postinst) and macOS cruft.
  find "$STAGE" -name icon-theme.cache -delete 2>/dev/null || true
  find "$STAGE" -name .DS_Store -delete 2>/dev/null || true
  find "$STAGE" -name .uuid -delete 2>/dev/null || true

  # Normalise ownership and permissions.
  chown -R root:root "$STAGE"
  find "$STAGE" -type d -exec chmod 0755 {} +
  find "$STAGE" -type f -exec chmod 0644 {} +
  chmod 0755 "$STAGE/DEBIAN/postinst"

  dpkg-deb -Zzstd -b "$STAGE" "/work/'"$DEB"'"
  echo "built /work/'"$DEB"'"
'
echo "==> $OUTDIR/$DEB"
