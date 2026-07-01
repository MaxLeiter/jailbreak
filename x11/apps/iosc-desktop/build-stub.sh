#!/usr/bin/env bash
# Build the two native binaries the iosc desktop launcher needs, HOST-SIDE on the
# Mac (Xcode clang + ldid — same toolchain bin/install-app.sh assumes). No device
# contact. Outputs go to out/ and are consumed by gen-launchers.sh + install-ioscd.sh.
#
#   x11/apps/iosc-desktop/build-stub.sh
#
#   out/IOSCLaunch   the per-app home-screen launcher (UIKit; signed launcher-ent.xml)
#                    copied verbatim into every generated .app bundle
#   out/ioscd        the root launch daemon (CLI; signed ioscd-ent.xml)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/src"
OUT="$HERE/out"
mkdir -p "$OUT"

SDK="$(xcrun -sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun -sdk iphoneos -f clang)"
MIN="-miphoneos-version-min=16.0"
TARGET="arm64-apple-ios16.0"
COMMON=(-arch arm64 -target "$TARGET" -isysroot "$SDK" $MIN -fobjc-arc -O2 -Wall)

echo "==> compiling IOSCLaunch (launcher stub, UIKit)"
"$CLANG" "${COMMON[@]}" \
  -framework UIKit -framework Foundation \
  "$SRC/IOSCLaunch.m" -o "$OUT/IOSCLaunch"

echo "==> compiling ioscd (root daemon, CLI)"
"$CLANG" -arch arm64 -target "$TARGET" -isysroot "$SDK" $MIN -O2 -Wall \
  "$SRC/ioscd.c" -o "$OUT/ioscd"

echo "==> pseudo-signing with ldid"
ldid -S"$HERE/launcher-ent.xml" "$OUT/IOSCLaunch"
ldid -S"$HERE/ioscd-ent.xml"    "$OUT/ioscd"

echo "==> done"
ls -la "$OUT/IOSCLaunch" "$OUT/ioscd"
echo "    IOSCLaunch entitlements:"; ldid -e "$OUT/IOSCLaunch" | grep -E "no-container|amfi|files.absolute" | sed 's/^/      /' || true
