#!/usr/bin/env bash
# Package Xios accessibility smoke/debug tools.
#
# Inputs:
#   out/atspi-dump, out/xios-a11yd  built by build-atspi-dump.sh
#
# Output:
#   xios-a11y-tools_<ver>_iphoneos-arm64.deb in x11/linux-build/out and repo/debs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_x="$HERE"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"

REPO_ROOT="$(cd "$HERE/../.." && pwd)"
OUTDIR="$REPO_ROOT/x11/linux-build/out"
REPODEBS="$REPO_ROOT/repo/debs"
STAGEROOT=/private/tmp/xios-a11y-tools-deb
STAGE="$STAGEROOT/xios-a11y-tools"
VER="0.2.12"
ARCH="iphoneos-arm64"
DEB="xios-a11y-tools_${VER}_${ARCH}.deb"

[ -x "$HERE/out/atspi-dump" ] && [ -x "$HERE/out/xios-a11yd" ] || {
  echo "ERROR: $HERE/out/{atspi-dump,xios-a11yd} missing; run wayland/build-atspi-dump.sh first" >&2
  exit 1
}

rm -rf "$STAGEROOT"
mkdir -p "$STAGE/var/jb/usr/local/bin" "$STAGE/DEBIAN"
cp "$HERE/out/atspi-dump" "$STAGE/var/jb/usr/local/bin/atspi-dump"
cp "$HERE/out/xios-a11yd" "$STAGE/var/jb/usr/local/bin/xios-a11yd"
chmod 0755 "$STAGE/var/jb/usr/local/bin/atspi-dump"
chmod 0755 "$STAGE/var/jb/usr/local/bin/xios-a11yd"

if command -v ldid >/dev/null 2>&1; then
  xsign "$STAGE/var/jb/usr/local/bin/atspi-dump"
  xsign "$STAGE/var/jb/usr/local/bin/xios-a11yd"
fi

INSTKB=$(du -sk "$STAGE/var/jb" | cut -f1)
cat > "$STAGE/DEBIAN/control" <<EOF
Package: xios-a11y-tools
Name: Xios accessibility tools
Version: ${VER}
Architecture: ${ARCH}
Maintainer: Max Leiter <maxwell.leiter@gmail.com>
Author: Max Leiter <maxwell.leiter@gmail.com>
Depends: at-spi2-core, libatspi2.0-0, libglib2.0-0, dbus
Section: X11
Priority: optional
Installed-Size: ${INSTKB}
Description: accessibility smoke tools for Xios
 xios-a11y-tools installs small command-line probes and early bridge helpers for
 the Xios accessibility work. atspi-dump connects to the current AT-SPI bus and
 prints the registered desktop/application accessibility trees, including exposed
 states, action names, and value ranges. xios-a11yd is
 the first read-only AT-SPI to Xios NDJSON helper; it listens on
 /var/jb/tmp/xios-a11y.sock, polls the AT-SPI tree, republishes only when the
 snapshot changes, routes basic activate/custom-action requests back to AT-SPI
 Action.DoAction, and falls back to synthetic taps for activations without an
 AT-SPI action. It also publishes AT-SPI Value text/current values and routes
 adjustable increment/decrement requests to Value.SetCurrentValue. Client
 commands are parsed as line-buffered NDJSON and dispatched by exact "t" type.
 Snapshots also include AT-SPI state-derived traits, state values, and focused
 node updates for VoiceOver focus sync smokes.
EOF

mkdir -p "$OUTDIR" "$REPODEBS"
built="$(xmkdeb "$STAGE" "$OUTDIR")"
cp "$built" "$REPODEBS/${DEB}"
echo "=== DEB BUILT ==="
ls -la "$OUTDIR/${DEB}" "$REPODEBS/${DEB}"
