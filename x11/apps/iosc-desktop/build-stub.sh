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
_x="$HERE"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"
SRC="$HERE/src"
OUT="$HERE/out"
mkdir -p "$OUT"

echo "==> testing trusted desktop-entry parser"
bash "$HERE/test-desktop-entry.sh"

echo "==> testing ioscd's libiosexec exec routing"
bash "$HERE/test-iosexec.sh"

echo "==> testing ioscd's session-bus adoption against planted links"
bash "$HERE/test-session-bus.sh"

echo "==> testing that ioscd's children inherit none of its fds"
bash "$HERE/test-ioscd-fds.sh"

SDK="$(xcrun -sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun -sdk iphoneos -f clang)"
MIN="-miphoneos-version-min=16.0"
TARGET="arm64-apple-ios16.0"
COMMON=(-arch arm64 -target "$TARGET" -isysroot "$SDK" $MIN -fobjc-arc -O2 -Wall)

echo "==> compiling IOSCLaunch (launcher stub, UIKit)"
"$CLANG" "${COMMON[@]}" \
  -framework UIKit -framework Foundation \
  "$SRC/IOSCLaunch.m" -o "$OUT/IOSCLaunch"

# ioscd execs through Procursus libiosexec so "#!/bin/sh" Exec targets work on
# rootless (src/xios-iosexec.h). Weak-linked against the in-tree link stub;
# the rpath is where libiosexec1 installs the dylib for the selected prefix.
IOSEXEC_RPATH="${XIOS_PREFIX-/var/jb}/usr/lib"
echo "==> compiling ioscd (root daemon, CLI)"
"$CLANG" -arch arm64 -target "$TARGET" -isysroot "$SDK" $MIN -O2 -Wall \
  "$SRC/ioscd.c" "$SRC/xios-desktop-entry.c" \
  -L"$HERE/sdk" -weak-liosexec -Wl,-rpath,"$IOSEXEC_RPATH" \
  -o "$OUT/ioscd"
bash "$HERE/test-iosexec.sh" --binary "$OUT/ioscd"

echo "==> pseudo-signing with ldid"
xsign "$OUT/IOSCLaunch" "$HERE/launcher-ent.xml"
xsign "$OUT/ioscd"      "$HERE/ioscd-ent.xml" platform-application

echo "==> done"
ls -la "$OUT/IOSCLaunch" "$OUT/ioscd"
echo "    IOSCLaunch entitlements:"; ldid -e "$OUT/IOSCLaunch" | grep -E "no-container|amfi|files.absolute" | sed 's/^/      /' || true
