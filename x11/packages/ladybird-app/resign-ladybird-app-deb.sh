#!/usr/bin/env bash
# Re-sign a container-built Ladybird.app deb with host ldid so IOKit/IOSurface
# entitlements are DER-encoded for iOS 15+ AMFI, then repack the same version.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
X11="$(cd "$HERE/../.." && pwd)"
. "$X11/lib/xlib.sh"

IN="${1:-}"
OUT_DIR="${2:-}"
[ -n "$IN" ] && [ -f "$IN" ] || {
    echo "usage: $0 <ladybird-app_..._iphoneos-arm64.deb> [out-dir]" >&2
    exit 2
}
IN="$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")"
OUT_DIR="${OUT_DIR:-$(dirname "$IN")}"

APP_ENTS="$HERE/entitlements/ladybird-app.entitlements"
HELPER_ENTS="$HERE/entitlements/ladybird-helper.entitlements"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/ar" "$WORK/stage/DEBIAN"
(
    cd "$WORK/ar"
    ar x "$IN"
    control_tar="$(ls control.tar.* | head -1)"
    data_tar="$(ls data.tar.* | head -1)"
    tar -xf "$control_tar" -C "$WORK/stage/DEBIAN"
    tar -xf "$data_tar" -C "$WORK/stage"
)

APP="$WORK/stage/var/jb/Applications/Ladybird.app"
[ -d "$APP" ] || { echo "missing Ladybird.app in $IN" >&2; exit 1; }

xsign "$APP/Ladybird" "$APP_ENTS" \
    com.apple.private.amfi.can-allow-non-platform \
    AGXDeviceUserClient \
    IOSurfaceRootUserClient

for h in WebContent RequestServer ImageDecoder WebWorker Compositor; do
    [ -f "$APP/$h" ] || { echo "missing helper: $APP/$h" >&2; exit 1; }
    xsign "$APP/$h" "$HELPER_ENTS" \
        com.apple.private.amfi.can-allow-non-platform \
        AGXDeviceUserClient \
        IOGPUDeviceUserClient \
        IOSurfaceRootUserClient \
        IOSurfaceAcceleratorClient
done

mkdir -p "$OUT_DIR"
signed="$(xmkdeb "$WORK/stage" "$WORK/out")"
out="$OUT_DIR/$(basename "$signed")"
mv -f "$signed" "$out"
echo "$out"
