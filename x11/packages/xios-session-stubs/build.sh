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
_x="$PKGDIR"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"

X11DIR="$(cd "$PKGDIR/../.." && pwd)"               # x11
STUBOUT="$X11DIR/wayland/out"
OUT="$X11DIR/linux-build/out"

echo "==> stage stub binaries from $STUBOUT"
# The libexec staging dir holds only build artifacts, so it isn't git-tracked; create it so a
# clean checkout doesn't fail the install below.
mkdir -p "$PKGDIR/var/jb/usr/libexec"
for b in xios-login1-stub xios-polkit-stub xios-accounts-stub; do
  [ -f "$STUBOUT/$b" ] || { echo "!! missing $STUBOUT/$b — run wayland/build-session-stubs.sh first"; exit 1; }
  install -m 0755 "$STUBOUT/$b" "$PKGDIR/var/jb/usr/libexec/$b"
done
# xios-bluez-stub (ObjC; org.bluez bridge backed by iOS BluetoothManager). Optional — the
# launcher guards it with -x — so stage it only if the ObjC stub built (needs the Foundation
# cross-toolchain path). It is already ldid-signed with com.apple.bluetooth.system by
# build-session-stubs.sh; do NOT re-sign here or the entitlement is lost.
if [ -f "$STUBOUT/xios-bluez-stub" ]; then
  install -m 0755 "$STUBOUT/xios-bluez-stub" "$PKGDIR/var/jb/usr/libexec/xios-bluez-stub"
  echo "   + xios-bluez-stub (org.bluez bridge)"
else
  echo "   (xios-bluez-stub absent — packaging without it; launcher -x guard covers it)"
fi
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
# Stage DEBIAN + var host-side (only these ship), set the perms, then let xmkdeb
# chown root:root + build the zstd .deb (in the cross-build container on macOS).
STAGEROOT=/private/tmp/xios-session-stubs-stage
STAGE="$STAGEROOT/xios-session-stubs"
rm -rf "$STAGEROOT"; mkdir -p "$STAGE"
cp -a "$PKGDIR/DEBIAN" "$PKGDIR/var" "$STAGE/"
find "$STAGE" -type d -exec chmod 0755 {} +
chmod 0755 "$STAGE/DEBIAN/postinst"
chmod 0755 "$STAGE/var/jb/usr/libexec/"* "$STAGE/var/jb/usr/bin/"*

# Re-sign the bluez stub with the com.apple.bluetooth.system entitlement using the Mac/Homebrew
# ldid (which DER-encodes the plist as iOS AMFI requires — the in-container Linux ldid does not).
# Verified on device: without this entitlement BluetoothManager returns no adapter/device data.
# Must run AFTER the chmod above and BEFORE xmkdeb (xmkdeb only chown+dpkg-debs, never re-signs).
BT_ENT="$X11DIR/wayland/xios-bluez-ent.xml"
if [ -f "$STAGE/var/jb/usr/libexec/xios-bluez-stub" ] && [ -f "$BT_ENT" ]; then
  xsign "$STAGE/var/jb/usr/libexec/xios-bluez-stub" "$BT_ENT" "com.apple.bluetooth.system"
fi

built="$(xmkdeb "$STAGE" "$OUT")"
# Keep the historical copy next to this script too.
cp -v "$built" "$PKGDIR/$DEB"
echo "==> built $DEB (copied to linux-build/out/)"
