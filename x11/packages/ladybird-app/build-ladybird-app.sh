#!/usr/bin/env bash
# build-ladybird-app.sh — assemble the Ladybird.app deb (home-screen browser).
#
# This is the MECHANICAL packaging driver that runs once the engine agent's build on
# procursus-vol-ladybird finishes. It does NOT build the engine; it consumes the engine's
# artifacts (the four helper executables + the built Lagom static libs + share/Lagom
# resources) and produces a signed, Sileo-installable .app deb.
#
# Pipeline:
#   1. [BLOCKED-ON-ENGINE] Cross-compile the UIKit frontend against the engine tree.
#      Copy Sources/ into <ladybird-src>/UI/iOS + this CMakeLists, add_subdirectory it,
#      build the `Ladybird` target with the SAME Docker cross toolchain the engine used
#      (clang-19 + cctools ld64 + iPhoneOS16.5.sdk + -D__IOS__), producing the UI Mach-O.
#   2. Assemble Ladybird.app (bundle root layout below).
#   3. ldid-sign (host Mac ldid, DER entitlements) the UI exe + each helper.
#   4. xmkdeb -> ladybird-app_<ver>_iphoneos-arm64.deb.
#
# Bundle layout (self-contained; see IOSApplication.mm header for why):
#   Ladybird.app/
#     Ladybird            UI executable (statically links the engine)
#     WebContent          helper  (found via same-dir candidate app_dir/WebContent)
#     RequestServer       helper
#     ImageDecoder        helper
#     WebWorker           helper
#     share/Lagom/...     engine resources (resource root overridden to here at boot)
#     Info.plist
#     AppIcon*.png
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
X11="$(cd "$HERE/../.." && pwd)"
. "$X11/lib/xlib.sh"

VER="${LADYBIRD_APP_VERSION:-0.1.0+ios1}"
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
BLOCKED ON ENGINE. Set:
  LADYBIRD_ENGINE_STAGE=<dir containing WebContent, RequestServer, ImageDecoder,
                         WebWorker, and share/Lagom>   (from procursus-vol-ladybird)
  LADYBIRD_UI_BIN=<path to the cross-built UIKit 'Ladybird' Mach-O>
Then re-run. Until the engine build lands + step-1 cross-compile is wired, this driver
stops here by design.
EOF
    exit 3
fi

STAGE="$(mktemp -d)"
APP="$STAGE/var/jb/Applications/Ladybird.app"
mkdir -p "$APP/share"

# --- Step 2: assemble bundle ---
cp "$UI_BIN" "$APP/Ladybird"
for h in WebContent RequestServer ImageDecoder WebWorker; do
    [ -f "$ENGINE_STAGE/$h" ] || die "missing helper: $ENGINE_STAGE/$h"
    cp "$ENGINE_STAGE/$h" "$APP/$h"
done
cp -R "$ENGINE_STAGE/share/Lagom" "$APP/share/Lagom"
cp "$HERE/Resources/Info.plist" "$APP/Info.plist"
[ -f "$HERE/Resources/AppIcon.png" ] && cp "$HERE/Resources/AppIcon.png" "$APP/AppIcon.png"
chmod +x "$APP/Ladybird" "$APP/WebContent" "$APP/RequestServer" "$APP/ImageDecoder" "$APP/WebWorker"

# --- Step 3: sign (Mac ldid, DER ents; xsign verifies markers) ---
xsign "$APP/Ladybird" "$APP_ENTS" com.apple.private.amfi.can-allow-non-platform
for h in WebContent RequestServer ImageDecoder WebWorker; do
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
