#!/usr/bin/env bash
# Reproducible cross-build of OpenTUI's native Zig render library for
# jailbroken iOS (rootless / palera1n, Procursus at /var/jb).
#
# OpenTUI (@opentui/core, used by the opencode TUI) dlopens a native render
# library through bun:ffi. Upstream ships only desktop artifacts; this script
# produces the aarch64 iPhoneOS dylib the resolver expects, with the same
# exported-symbol surface as the macOS build.
#
# The build patches upstream's build.zig to add an `aarch64-ios.16.0` target.
# The one wrinkle is audio: miniaudio's CoreAudio backend on iOS drives
# AVAudioSession via Objective-C, so the shim is compiled from a `.m` wrapper
# (miniaudio_shim_ios.m) and the Apple audio frameworks are linked from the
# iPhoneOS SDK named by IOS_SDK_PATH.
#
# Host-side zig build with pinned versions is the standard here for this
# package (no Docker). Produces out/opentui-ios/libopentui.dylib, fakesigned.
set -euo pipefail
umask 022
export LC_ALL=C
export TZ=UTC

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$HERE/out}"
WORK="${WORK:-$OUT/opentui-ios-work}"
PATCH_DIR="${OPENTUI_PATCH_DIR:-$HERE/patches/opentui}"

# Pins: opentui tag v0.3.4 (matches @opentui/core@0.3.4), zig 0.15.2 (hard
# requirement checked by build.zig's checkZigVersion / build.zig.zon).
OPENTUI_REPO="${OPENTUI_REPO:-https://github.com/anomalyco/opentui.git}"
OPENTUI_COMMIT="${OPENTUI_COMMIT:-9b216a58d974704ae638b3043aece2eb70b5ff19}"  # tag v0.3.4
ZIG_VERSION="${ZIG_VERSION:-0.15.2}"
IOS_MIN="${IOS_MIN:-16.0}"                        # device is 17.6.1; 16.0 floor
ZIG_TARGET="${ZIG_TARGET:-aarch64-ios.${IOS_MIN}}"

need() { command -v "$1" >/dev/null || { echo "$1 not found" >&2; exit 1; }; }
need git
need xcrun
need curl
need tar

[ -f "$PATCH_DIR/0001-ios-target.patch" ] || { echo "missing $PATCH_DIR/0001-ios-target.patch" >&2; exit 1; }
[ -f "$PATCH_DIR/miniaudio_shim_ios.m" ]   || { echo "missing $PATCH_DIR/miniaudio_shim_ios.m" >&2; exit 1; }

mkdir -p "$WORK" "$OUT/opentui-ios"

# --- zig 0.15.2 (host toolchain) ---
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  arm64|aarch64) ZARCH=aarch64 ;;
  x86_64)        ZARCH=x86_64 ;;
  *) echo "unsupported host arch: $HOST_ARCH" >&2; exit 1 ;;
esac
ZIG_DIR="$WORK/zig-${ZARCH}-macos-${ZIG_VERSION}"
if [ ! -x "$ZIG_DIR/zig" ]; then
  echo "==> fetch zig ${ZIG_VERSION}"
  curl -fsSL -o "$WORK/zig.tar.xz" \
    "https://ziglang.org/download/${ZIG_VERSION}/zig-${ZARCH}-macos-${ZIG_VERSION}.tar.xz"
  tar -C "$WORK" -xf "$WORK/zig.tar.xz"
fi
export PATH="$ZIG_DIR:$PATH"
[ "$(zig version)" = "$ZIG_VERSION" ] || { echo "zig version mismatch" >&2; exit 1; }

# --- source ---
SRC="$WORK/opentui"
if [ ! -d "$SRC/.git" ]; then
  git clone "$OPENTUI_REPO" "$SRC"
fi
git -C "$SRC" fetch --quiet origin "$OPENTUI_COMMIT" || git -C "$SRC" fetch --quiet --tags
git -C "$SRC" checkout --quiet "$OPENTUI_COMMIT"
git -C "$SRC" reset --quiet --hard "$OPENTUI_COMMIT"
git -C "$SRC" clean -fd --quiet packages/core/src/zig

ZDIR="$SRC/packages/core/src/zig"
git -C "$SRC" apply "$PATCH_DIR/0001-ios-target.patch"
cp "$PATCH_DIR/miniaudio_shim_ios.m" "$ZDIR/miniaudio_shim_ios.m"

# --- SDKs ---
export IOS_SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
MACOS_SDK="$(xcrun --sdk macosx --show-sdk-path)"   # build.zig's test/bench graph needs a macOS SDK to resolve

echo "==> build libopentui.dylib for $ZIG_TARGET (iOS SDK: $IOS_SDK_PATH)"
(
  cd "$ZDIR"
  zig build \
    -Dtarget="$ZIG_TARGET" \
    -Doptimize=ReleaseFast \
    -Dmacos-sdk="$MACOS_SDK" \
    --summary all
)

BUILT="$ZDIR/lib/aarch64-ios/libopentui.dylib"
[ -f "$BUILT" ] || { echo "expected artifact missing: $BUILT" >&2; exit 1; }

# --- verify Mach-O is arm64 iOS (LC_BUILD_VERSION platform 2 == IOS) ---
otool -l "$BUILT" | grep -A3 LC_BUILD_VERSION | grep -q "platform 2" \
  || { echo "artifact is not an iOS (platform 2) binary" >&2; exit 1; }

# Symbol count must be read from the UNSIGNED binary: Apple's cctools nm cannot
# parse the LINKEDIT layout ldid produces, though the file still loads fine.
SYMS="$(nm -gU "$BUILT" | wc -l | tr -d ' ')"

# --- fakesign ---
if command -v ldid >/dev/null; then
  ldid -S "$BUILT"
else
  echo "ldid not on host; sign on device after copy (ldid -S)" >&2
fi

cp "$BUILT" "$OUT/opentui-ios/libopentui.dylib"
echo "==> built $OUT/opentui-ios/libopentui.dylib"
echo "    install-name:     $(otool -D "$BUILT" | tail -1)"
echo "    exported symbols: $SYMS"
