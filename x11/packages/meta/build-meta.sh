#!/usr/bin/env bash
# Build the five Xios flavor meta-packages (control-only .debs).
#
# xios-core, xios-gnome, xios-kde, xios-native, xios-x11 carry no files; they
# exist so `sileo install xios-<flavor>` pulls a complete desktop flavor via
# Depends, and so the store can gate flavors by MinimumOSVersion / firmware.
#
# Like the sibling packages, dpkg-deb runs in a Debian container so the debs
# are reproducible on any host with Docker. Output lands next to this script
# AND is copied into x11/linux-build/out/ so tools/stamp-minos.py (the FINAL
# pre-publish step) recomputes each meta's effective dependency-closure floor
# together with the rest of the catalog. The MinimumOSVersion baked in each
# control is the design floor; the stamp is authoritative at publish time.
set -euo pipefail

METADIR="$(cd "$(dirname "$0")" && pwd)"            # x11/packages/meta
_x="$METADIR"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"

X11DIR="$(cd "$METADIR/../.." && pwd)"              # x11
OUT="$X11DIR/linux-build/out"

# Each flavor meta is control-only: stage its DEBIAN dir host-side, set the perms,
# then let xmkdeb chown root:root + build the zstd .deb (in the cross-build
# container on a macOS host).
for pkgdir in xios-core xios-gnome xios-kde xios-native xios-x11; do
  stageroot="/private/tmp/xios-meta-stage/$pkgdir"
  stage="$stageroot/$pkgdir"
  rm -rf "$stageroot"; mkdir -p "$stage"
  cp -a "$METADIR/$pkgdir/DEBIAN" "$stage/"
  find "$stage" -type d -exec chmod 0755 {} +
  find "$stage" -type f -exec chmod 0644 {} +
  built="$(xmkdeb "$stage" "$OUT")"
  # Keep the historical copy next to this script too.
  cp -v "$built" "$METADIR/"
done

echo "==> built $(ls "$METADIR"/xios-*_*_iphoneos-arm64.deb | wc -l | tr -d ' ') meta debs (copied to linux-build/out/)"
