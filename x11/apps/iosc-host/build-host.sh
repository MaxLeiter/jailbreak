#!/usr/bin/env bash
# Builds the per-app host app (host-side, Mac). Produces the shared prebuilt
# payload gen-launchers.sh --native copies into every per-app bundle:
# out/IOSCHost + out/default.metallib.
#
# Codesigning is off (like apps/Xios); device install pseudo-signs with
# `ldid -S entitlements.plist`. No device contact.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_x="$HERE"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"
OUT="$HERE/out"
mkdir -p "$OUT"

# XcodeGen the project (mirrors apps/Xios). Requires `xcodegen` (brew install xcodegen).
if command -v xcodegen >/dev/null 2>&1; then
  ( cd "$HERE" && xcodegen generate )
else
  echo "error: xcodegen not found (brew install xcodegen)"; exit 1
fi

CONFIG=Release
DERIVED="$HERE/build"
echo "==> xcodebuild ($CONFIG, iphoneos, unsigned)"
xcodebuild \
  -project "$HERE/IOSCHost.xcodeproj" \
  -scheme IOSCHost \
  -configuration "$CONFIG" \
  -sdk iphoneos \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build

APP="$DERIVED/Build/Products/$CONFIG-iphoneos/IOSCHost.app"
[ -d "$APP" ] || { echo "error: build produced no IOSCHost.app at $APP"; exit 1; }

cp "$APP/IOSCHost"        "$OUT/IOSCHost"
cp "$APP/default.metallib" "$OUT/default.metallib"
chmod 0755 "$OUT/IOSCHost"

echo "==> pseudo-signing the host binary"
xsign "$OUT/IOSCHost" "$HERE/entitlements.plist" \
  AGXDeviceUserClient IOGPUDeviceUserClient IOSurfaceRootUserClient

echo "==> done"
ls -la "$OUT/IOSCHost" "$OUT/default.metallib"
echo "    (gen-launchers.sh --native copies both into each per-app bundle)"
