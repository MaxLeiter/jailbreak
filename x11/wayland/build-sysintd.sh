#!/usr/bin/env bash
# Build xios-sysintd (session-side iOS system-integration daemon: hardware
# volume -> PA sink, iOS light/dark -> gsettings) for rootless iOS.
#
# No library deps beyond libc + the shared record reader (xios_input_socket.c),
# so unlike iosc this builds either way:
#   - on the Mac:      ./build-sysintd.sh          (uses xcrun + iPhoneOS SDK)
#   - in the Procursus image: same entrypoint as build-session-stubs.sh
# Output: out/xios-sysintd (arm64; ad-hoc signed when ldid is available).
set -euo pipefail
umask 022

SRC="$(cd "$(dirname "$0")" && pwd)"
OUT="$SRC/out"
mkdir -p "$OUT"

CFLAGS="-arch arm64 -miphoneos-version-min=16.0 -O2 -Wall -Wextra -Wno-unused-parameter"

if command -v xcrun >/dev/null 2>&1 && xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
  CC="xcrun --sdk iphoneos clang"
else
  # Procursus cross image (see build-session-stubs.sh for the toolchain layout).
  CC=""
  for cand in aarch64-apple-darwin-clang arm64-apple-darwin-clang aarch64-apple-darwin20-clang; do
    command -v "$cand" >/dev/null 2>&1 && { CC="$cand"; break; }
  done
  [ -n "$CC" ] || { echo "!! no xcrun and no cross clang"; exit 1; }
  SDK="$(dirname "$(command -v "$CC")")/../SDK/iPhoneOS.sdk"
fi

echo "==> cc: $CC (SDK $SDK)"
$CC $CFLAGS -isysroot "$SDK" -I"$SRC" \
    -o "$OUT/xios-sysintd" "$SRC/xios-sysintd.c" "$SRC/xios_input_socket.c"

if command -v ldid >/dev/null 2>&1; then
  ldid -S "$OUT/xios-sysintd"
  echo "==> signed (ldid -S)"
else
  echo "!! ldid not found — sign on device before running"
fi
echo "==> built $OUT/xios-sysintd"
