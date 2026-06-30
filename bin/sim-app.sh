#!/usr/bin/env bash
# Build KitchenHub for the iOS Simulator, launch it, and grab a screenshot — so
# the design can be iterated visually without the device. Uses an iPad Pro 13"
# (4:3, same aspect as the iPad 7) by default.
#
# Usage: bin/sim-app.sh [app-dir]
#   SIM_NAME="iPad Pro 13-inch (M4)"  override device
#   SHOT=/path/out.png                override screenshot path
#   WAIT=6                            seconds to wait before screenshot
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${1:-$REPO_ROOT/apps/KitchenHub}"
APP_NAME="KitchenHub"
BUNDLE_ID="com.max.kitchenhub"
SIM_NAME="${SIM_NAME:-iPad Pro 13-inch (M4)}"
OUT="${SHOT:-$APP_DIR/.preview.png}"

cd "$APP_DIR"
xcodegen generate >/dev/null

UDID="$(xcrun simctl list devices available | grep -F "$SIM_NAME (" | head -1 | grep -oE '[0-9A-Fa-f-]{36}')"
[ -n "$UDID" ] || { echo "error: no available simulator named '$SIM_NAME'" >&2; exit 1; }
echo "==> Simulator: $SIM_NAME ($UDID)"

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" >/dev/null 2>&1 || true

echo "==> Building (simulator)"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Debug \
  -sdk iphonesimulator -derivedDataPath build-sim \
  -destination "platform=iOS Simulator,id=$UDID" -quiet build

APP="build-sim/Build/Products/Debug-iphonesimulator/$APP_NAME.app"
[ -d "$APP" ] || { echo "error: build produced no app" >&2; exit 1; }

xcrun simctl install "$UDID" "$APP"
xcrun simctl privacy "$UDID" grant location "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl location "$UDID" set 40.7128,-74.0060 2>/dev/null || true
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl launch "$UDID" "$BUNDLE_ID"

sleep "${WAIT:-6}"
xcrun simctl io "$UDID" screenshot "$OUT"
echo "==> Screenshot: $OUT"
