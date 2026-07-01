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
X11DIR="$(cd "$METADIR/../.." && pwd)"              # x11
OUT="$X11DIR/linux-build/out"
IMAGE="debian:bookworm-slim"

docker run --rm -v "$METADIR":/work -w /work "$IMAGE" bash -euo pipefail -c '
  for pkgdir in xios-core xios-gnome xios-kde xios-native xios-x11; do
    ver="$(awk -F": " "/^Version:/{print \$2}" "$pkgdir/DEBIAN/control")"
    deb="${pkgdir}_${ver}_iphoneos-arm64.deb"
    stage=/tmp/stage-$pkgdir
    rm -rf "$stage"; mkdir -p "$stage"
    cp -a "$pkgdir/DEBIAN" "$stage/"
    chown -R root:root "$stage"
    find "$stage" -type d -exec chmod 0755 {} +
    find "$stage" -type f -exec chmod 0644 {} +
    dpkg-deb -Zzstd -b "$stage" "/work/$deb"
  done
'

mkdir -p "$OUT"
for deb in "$METADIR"/xios-*_*_iphoneos-arm64.deb; do
  cp -v "$deb" "$OUT/"
done
echo "==> built $(ls "$METADIR"/xios-*_*_iphoneos-arm64.deb | wc -l | tr -d ' ') meta debs (copied to linux-build/out/)"
