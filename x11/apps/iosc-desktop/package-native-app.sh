#!/usr/bin/env bash
# Package one freedesktop application as an independent iPadOS multi-window
# IOSCHost bundle. The application itself stays in its normal deb; this package
# contains only the SpringBoard/native host and depends on that application.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
X11_ROOT="$(cd "$HERE/../.." && pwd)"
. "$X11_ROOT/lib/xlib.sh"
. "$X11_ROOT/linux-build/target-lib.sh"
xios_load_target "${XIOS_TARGET:-rootless-1900}"

APP_DEB=""
DESKTOP_NAME=""
PACKAGE=""
VERSION=""
DEPENDS=""
BUNDLE_NAME=""
BUNDLE_BASENAME=""
DESCRIPTION=""
OUT="$X11_ROOT/linux-build/out"

usage() {
  echo "usage: $0 --app-deb FILE --desktop FILE.desktop --package NAME --version VERSION \\"
  echo "          --depends LIST --bundle-name NAME [--bundle-basename NAME] \\"
  echo "          [--description TEXT] [--out DIR]"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app-deb) APP_DEB="$2"; shift 2 ;;
    --desktop) DESKTOP_NAME="$2"; shift 2 ;;
    --package) PACKAGE="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --depends) DEPENDS="$2"; shift 2 ;;
    --bundle-name) BUNDLE_NAME="$2"; shift 2 ;;
    --bundle-basename) BUNDLE_BASENAME="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for value in APP_DEB DESKTOP_NAME PACKAGE VERSION DEPENDS BUNDLE_NAME; do
  [ -n "${!value}" ] || { echo "error: --$(echo "$value" | tr A-Z_ a-z-) is required" >&2; exit 2; }
done
[ -f "$APP_DEB" ] || { echo "error: application deb not found: $APP_DEB" >&2; exit 2; }

[ -n "$BUNDLE_BASENAME" ] || BUNDLE_BASENAME="$BUNDLE_NAME"
DESCRIPTION="${DESCRIPTION:-native iPadOS multi-window host for $BUNDLE_NAME}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/xios-native-app.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
APP_ROOT="$WORK/app-root"
mkdir -p "$APP_ROOT"

extract_data_tar() {
  local deb="$1" dest="$2" ardir data
  ardir="$WORK/ar"
  rm -rf "$ardir"
  mkdir -p "$ardir"
  (cd "$ardir" && ar x "$deb")
  data="$(find "$ardir" -maxdepth 1 -type f -name 'data.tar.*' | head -1)"
  [ -n "$data" ] || { echo "error: no data archive in $deb" >&2; exit 2; }
  case "$data" in
    *.zst) zstd -dc "$data" | tar -xf - -C "$dest" ;;
    *.xz) xz -dc "$data" | tar -xf - -C "$dest" ;;
    *.gz) gzip -dc "$data" | tar -xf - -C "$dest" ;;
    *) tar -xf "$data" -C "$dest" ;;
  esac
}

extract_data_tar "$APP_DEB" "$APP_ROOT"
SHARE="$APP_ROOT$XIOS_PREFIX/usr/share"
DESKTOP="$SHARE/applications/$DESKTOP_NAME"
[ -f "$DESKTOP" ] || { echo "error: $DESKTOP_NAME is not present in $APP_DEB" >&2; exit 2; }

# Always pair a package with the current host protocol and shader, rather than
# silently embedding a stale cached IOSCHost.
bash "$X11_ROOT/apps/iosc-host/build-host.sh"
NATIVE_BUNDLES="$WORK/native-bundles"
bash "$HERE/gen-launchers.sh" \
  --native \
  --icons-root "$SHARE" \
  --out "$NATIVE_BUNDLES" \
  "$DESKTOP"

GENERATED_APP="$(find "$NATIVE_BUNDLES" -maxdepth 1 -type d -name '*.app' | head -1)"
[ -n "$GENERATED_APP" ] || { echo "error: native bundle was not generated" >&2; exit 2; }

PLIST="$GENERATED_APP/Info.plist"
PB=/usr/libexec/PlistBuddy
"$PB" -c "Set :CFBundleName $BUNDLE_NAME" "$PLIST"
"$PB" -c "Set :CFBundleDisplayName $BUNDLE_NAME" "$PLIST"
"$PB" -c "Set :IOSCName $BUNDLE_NAME" "$PLIST"
"$PB" -c "Set :CFBundleShortVersionString ${VERSION%%+*}" "$PLIST"
"$PB" -c "Set :CFBundleVersion 1" "$PLIST"
"$PB" -c "Delete :IOSCExec" "$PLIST" >/dev/null 2>&1 || true

STAGE="$WORK/$PACKAGE"
APP_DEST="$STAGE$XIOS_PREFIX/Applications/$BUNDLE_BASENAME.app"
mkdir -p "$STAGE/DEBIAN" "$(dirname "$APP_DEST")"
cp -a "$GENERATED_APP" "$APP_DEST"

cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: $PACKAGE
Version: $VERSION
Architecture: $XIOS_DEB_ARCH
Maintainer: Max Leiter <max@maxleiter.com>
Section: Applications
Priority: optional
Depends: $DEPENDS
Description: $DESCRIPTION
 Independent UIKit scene host for the Xios application, with IOSurface/Metal
 presentation and iPadOS multi-window support.
CONTROL

cat > "$STAGE/DEBIAN/postinst" <<POSTINST
#!/var/jb/bin/sh
chmod 0755 "$XIOS_PREFIX/Applications/$BUNDLE_BASENAME.app/IOSCHost" 2>/dev/null || true
$XIOS_PREFIX/usr/bin/uicache -p "$XIOS_PREFIX/Applications/$BUNDLE_BASENAME.app" >/dev/null 2>&1 || true
exit 0
POSTINST
cat > "$STAGE/DEBIAN/postrm" <<POSTRM
#!/var/jb/bin/sh
$XIOS_PREFIX/usr/bin/uicache -u "$XIOS_PREFIX/Applications/$BUNDLE_BASENAME.app" >/dev/null 2>&1 || true
exit 0
POSTRM
chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm" "$APP_DEST/IOSCHost"

# The generated host is already signed, but reapply and verify the narrow,
# protocol-current GPU/IOSurface and native-socket entitlement profile last.
xsign "$APP_DEST/IOSCHost" \
  "$X11_ROOT/apps/iosc-host/entitlements.plist" \
  AGXDeviceUserClient IOGPUDeviceUserClient IOSurfaceRootUserClient \
  com.max.xios.metal-event-broker \
  com.apple.security.exception.files.absolute-path.read-write

xmkdeb "$STAGE" "$OUT" --minos
