#!/usr/bin/env bash
# Build the xios-session-stubs .deb (the three GNOME-session freedesktop stub daemons).
#
# The stub BINARIES are cross-compiled separately by x11/wayland/build-session-stubs.sh into
# x11/wayland/out/. This script stages those binaries plus the launcher into the package tree
# and runs dpkg-deb in a Debian container so the deb is reproducible on any host with Docker.
# Output lands next to this script AND is copied into x11/linux-build/out/ so
# tools/stamp-minos.py (the FINAL pre-publish step) recomputes the effective min-iOS floor
# together with the rest of the catalog.
#
# Run x11/wayland/build-session-stubs.sh FIRST (it produces the binaries this packages).
set -euo pipefail

PKGDIR="$(cd "$(dirname "$0")" && pwd)"             # x11/packages/xios-session-stubs
X11DIR="$(cd "$PKGDIR/../.." && pwd)"               # x11
STUBOUT="$X11DIR/wayland/out"
OUT="$X11DIR/linux-build/out"
IMAGE="debian:bookworm-slim"

echo "==> stage stub binaries from $STUBOUT"
for b in xios-login1-stub xios-polkit-stub xios-accounts-stub; do
  [ -f "$STUBOUT/$b" ] || { echo "!! missing $STUBOUT/$b — run wayland/build-session-stubs.sh first"; exit 1; }
  install -m 0755 "$STUBOUT/$b" "$PKGDIR/var/jb/usr/libexec/$b"
done
# xios-sysintd (native-bundle: iPad volume buttons -> PA + iOS dark-mode -> GTK). Optional — the
# launcher guards it with -x — so stage it only if native-bundle has built it (wayland/
# build-sysintd.sh); otherwise ship without it.
if [ -f "$STUBOUT/xios-sysintd" ]; then
  install -m 0755 "$STUBOUT/xios-sysintd" "$PKGDIR/var/jb/usr/libexec/xios-sysintd"
  echo "   + xios-sysintd"
else
  echo "   (xios-sysintd absent — packaging without it; launcher -x guard covers it)"
fi
chmod 0755 "$PKGDIR/var/jb/usr/bin/launch-gnome-session.sh"

VER="$(awk -F': ' '/^Version:/{print $2}' "$PKGDIR/DEBIAN/control")"
DEB="xios-session-stubs_${VER}_iphoneos-arm64.deb"

echo "==> dpkg-deb build $DEB"
docker run --rm -v "$PKGDIR":/pkg -v "$PKGDIR":/work -w /work "$IMAGE" bash -euo pipefail -c '
  stage=/tmp/stage-xios-session-stubs
  rm -rf "$stage"; mkdir -p "$stage"
  cp -a /pkg/DEBIAN /pkg/var "$stage/"
  chown -R root:root "$stage"
  find "$stage" -type d -exec chmod 0755 {} +
  chmod 0755 "$stage/DEBIAN/postinst"
  chmod 0755 "$stage/var/jb/usr/libexec/"* "$stage/var/jb/usr/bin/"*
  dpkg-deb -Zzstd -b "$stage" "/work/'"$DEB"'"
'

mkdir -p "$OUT"
cp -v "$PKGDIR/$DEB" "$OUT/"
echo "==> built $DEB (copied to linux-build/out/)"
