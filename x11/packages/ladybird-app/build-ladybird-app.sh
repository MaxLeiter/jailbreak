#!/usr/bin/env bash
# Assembles Ladybird.app from an already-built engine (LADYBIRD_ENGINE_STAGE) and
# UI binary (LADYBIRD_UI_BIN), signs it, and packages the deb. Does not build the
# engine itself. The UI binary must be cross-compiled with the same Docker toolchain
# used for the engine build, or the helpers won't link/run against it.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
X11="$(cd "$HERE/../.." && pwd)"
. "$X11/lib/xlib.sh"

VER="${LADYBIRD_APP_VERSION:-0.1.23+ios1}"
ARCH="iphoneos-arm64"
ENGINE_STAGE="${LADYBIRD_ENGINE_STAGE:-}"     # dir with WebContent/RequestServer/... + share/Lagom
UI_BIN="${LADYBIRD_UI_BIN:-}"                 # the built UIKit `Ladybird` Mach-O (step 1 output)
OUT="${OUT:-$HERE/out}"
APP_ENTS="$HERE/entitlements/ladybird-app.entitlements"
HELPER_ENTS="$HERE/entitlements/ladybird-helper.entitlements"

die() { echo "build-ladybird-app: $*" >&2; exit 1; }

# --- Step 1 gate: engine + UI binary must exist ---
if [ -z "$ENGINE_STAGE" ] || [ -z "$UI_BIN" ]; then
    cat >&2 <<EOF
Set:
  LADYBIRD_ENGINE_STAGE=<dir containing WebContent, RequestServer, ImageDecoder,
                         WebWorker, Compositor, and share/Lagom>
  LADYBIRD_UI_BIN=<path to the cross-built UIKit 'Ladybird' Mach-O>
Then re-run.
EOF
    exit 3
fi

STAGE="$(mktemp -d)"
APP="$STAGE/var/jb/Applications/Ladybird.app"
mkdir -p "$APP/share"

# --- Step 2: assemble bundle ---
cp "$UI_BIN" "$APP/Ladybird"
for h in WebContent RequestServer ImageDecoder WebWorker Compositor; do
    [ -f "$ENGINE_STAGE/$h" ] || die "missing helper: $ENGINE_STAGE/$h"
    cp "$ENGINE_STAGE/$h" "$APP/$h"
done
cp -R "$ENGINE_STAGE/share/Lagom" "$APP/share/Lagom"
cp "$HERE/Resources/Info.plist" "$APP/Info.plist"
[ -f "$HERE/Resources/AppIcon.png" ] && cp "$HERE/Resources/AppIcon.png" "$APP/AppIcon.png"
chmod +x "$APP/Ladybird" "$APP/WebContent" "$APP/RequestServer" "$APP/ImageDecoder" "$APP/WebWorker" "$APP/Compositor"

# --- Step 3: sign (Mac ldid, DER ents; xsign verifies markers) ---
xsign "$APP/Ladybird" "$APP_ENTS" com.apple.private.amfi.can-allow-non-platform
for h in WebContent RequestServer ImageDecoder WebWorker Compositor; do
    xsign "$APP/$h" "$HELPER_ENTS" com.apple.private.amfi.can-allow-non-platform
done

# --- Step 4: control + deb ---
mkdir -p "$STAGE/DEBIAN"
sed "s/@VER@/$VER/" "$HERE/DEBIAN/control" > "$STAGE/DEBIAN/control"
cp "$HERE/DEBIAN/postinst" "$STAGE/DEBIAN/postinst"
chmod 0755 "$STAGE/DEBIAN/postinst"

mkdir -p "$OUT"
xmkdeb "$STAGE" "$OUT"
echo "built: $OUT (install, then it appears on the home screen after uicache)"
