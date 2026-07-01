#!/usr/bin/env bash
# build-host.sh — build the per-app host app (host-side, Mac). Produces the shared
# prebuilt payload that gen-launchers.sh --native copies into every per-app bundle:
#
#   out/IOSCHost         the host Mach-O (Metal present + input + native rendezvous)
#   out/default.metallib the compiled shader (makeDefaultLibrary loads it from the bundle)
#
# Like apps/Xios, codesigning is off; the device install pseudo-signs with
# `ldid -S entitlements.plist`. No device contact.
#
#   x11/apps/iosc-host/build-host.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
ldid -S"$HERE/entitlements.plist" "$OUT/IOSCHost"

echo "==> done"
ls -la "$OUT/IOSCHost" "$OUT/default.metallib"
echo "    (gen-launchers.sh --native copies both into each per-app bundle)"
