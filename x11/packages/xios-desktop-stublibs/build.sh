#!/usr/bin/env bash
# Build the xios-desktop-stublibs .deb: the four iOS stub libraries (libgudev-1.0, libudev,
# libpwquality, libgsound) that gnome-control-center + gnome-bluetooth link at runtime.
#
# The stub dylibs are produced by the build-*-stub.sh scripts in x11/linux-build/, which stage a
# runtime tree into x11/linux-build/out/<name>-stub-tree/. This script merges those trees, adds
# DEBIAN/control, and builds a root-owned zstd .deb via xmkdeb (into x11/linux-build/out/).
#
# Run the four builders FIRST (each installs into the volume sysroot AND stages a runtime tree):
#   build-gudev-stub.sh  build-udev-stub.sh  build-pwquality-stub.sh  build-gsound-stub.sh
set -euo pipefail
PKGDIR="$(cd "$(dirname "$0")" && pwd)"
_x="$PKGDIR"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"

X11DIR="$(cd "$PKGDIR/../.." && pwd)"
OUT="$X11DIR/linux-build/out"
. "$X11DIR/linux-build/target-lib.sh"

TARGET="${XIOS_TARGET:-rootless-1900}"
STAGE_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stage-only) STAGE_ONLY=1 ;;
    -h|--help)
      echo "usage: $0 [target-id] [--stage-only]" >&2
      exit 0
      ;;
    *) TARGET="$1" ;;
  esac
  shift
done

xios_load_target "$TARGET"

render_control() {
  XIOS_DEB_ARCH="$XIOS_DEB_ARCH" \
  XIOS_REPO_PROFILE="$XIOS_REPO_PROFILE" \
  perl -pe '
    s/\@DEB_ARCH\@/$ENV{XIOS_DEB_ARCH}/g;
    s/\@REPO_PROFILE\@/$ENV{XIOS_REPO_PROFILE}/g;
  ' "$1" > "$2"
}

echo "==> assembling stub-lib tree for $XIOS_TARGET_ID"
STAGEROOT="/private/tmp/xios-desktop-stublibs-stage/$XIOS_TARGET_ID"
STAGE="$STAGEROOT/xios-desktop-stublibs"
PAYLOAD_LIB="$STAGE$XIOS_PACKAGE_PATH_PREFIX$XIOS_SUBPREFIX/lib"
PKGOUT="$OUT"
PKGCOPY="$PKGDIR"
if [ "$XIOS_TARGET_ID" != "rootless-1900" ]; then
  PKGOUT="$OUT/targets/$XIOS_TARGET_ID"
  PKGCOPY="$PKGDIR/targets/$XIOS_TARGET_ID"
fi
rm -rf "$STAGEROOT"; mkdir -p "$PAYLOAD_LIB" "$STAGE/DEBIAN"
render_control "$X11DIR/packages/templates/xios-desktop-stublibs/DEBIAN/control.in" "$STAGE/DEBIAN/control"

n=0
for s in gudev udev pwquality gsound; do
  TREE="$OUT/${s}-stub-tree$XIOS_PACKAGE_PATH_PREFIX$XIOS_SUBPREFIX/lib"
  [ -d "$TREE" ] || { echo "!! missing $TREE — run build-${s}-stub.sh first"; exit 1; }
  cp -a "$TREE/." "$PAYLOAD_LIB/"
  n=$((n+1))
done
echo "   merged $n stub-lib trees"

find "$STAGE" -type d -exec chmod 0755 {} +
find "$PAYLOAD_LIB" -type f -name '*.dylib' -exec chmod 0755 {} +

if [ "$STAGE_ONLY" = 1 ]; then
  echo "==> staged xios-desktop-stublibs for $XIOS_TARGET_ID at $STAGE"
  find "$STAGE" -type f | sed "s#$STAGE/##" | sort
  exit 0
fi

mkdir -p "$PKGOUT" "$PKGCOPY"
built="$(xmkdeb "$STAGE" "$PKGOUT")"
cp -v "$built" "$PKGCOPY/$(basename "$built")"
echo "==> built $(basename "$built") (copied to $PKGOUT/)"
