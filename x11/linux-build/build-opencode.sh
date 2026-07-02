#!/usr/bin/env bash
# Reproducible OpenCode-on-iOS bring-up build.
#
# This produces a patched spike binary from the pinned upstream npm payload, but
# it refuses to emit the installable `opencode` deb unless the binary passes an
# on-device smoke test. Today the smoke test fails on iPad7,12/A10 with SIGILL
# in the upstream macOS Bun runtime, so this is a reproducible blocker harness,
# not a release path yet.
set -euo pipefail
umask 022
export LC_ALL=C
export TZ=UTC

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
OUT="${OUT:-$HERE/out}"
WORK="${WORK:-$OUT/opencode-work}"
LOCK="${OPENCODE_LOCK:-$HERE/build_info/opencode.lock}"
[ -f "$LOCK" ] || { echo "OpenCode lock file not found: $LOCK" >&2; exit 1; }
# shellcheck disable=SC1090
. "$LOCK"
NPM_PACKAGE="${OPENCODE_NPM_PACKAGE:-opencode-darwin-arm64}"
VERSION="${OPENCODE_VERSION:?OPENCODE_VERSION missing from $LOCK}"
IOS_MIN="${IOS_MIN:-16.0}"
IOS_SDK_VERSION="${IOS_SDK_VERSION:-26.2}"
PKG_VERSION="${VERSION}~ios0.1"
ARCH="iphoneos-arm64"
PKG="opencode_${PKG_VERSION}_${ARCH}.deb"
TARBALL="${NPM_PACKAGE}-${VERSION}.tgz"
NPM_SPEC="${NPM_PACKAGE}@${VERSION}"
EXPECTED_SHA512="${OPENCODE_TARBALL_SHA512:?OPENCODE_TARBALL_SHA512 missing from $LOCK}"

mkdir -p "$OUT" "$WORK/cache" "$WORK/stage"

need() { command -v "$1" >/dev/null || { echo "$1 not found" >&2; exit 1; }; }
need npm
need openssl
need vtool
need xcrun
need ldid

echo "==> fetch pinned OpenCode payload: $NPM_SPEC"
if [ ! -f "$WORK/cache/$TARBALL" ]; then
  (cd "$WORK/cache" && npm pack --ignore-scripts "$NPM_SPEC" >/dev/null)
fi

actual_sha512="$(openssl dgst -sha512 -binary "$WORK/cache/$TARBALL" | openssl base64 -A)"
if [ "$actual_sha512" != "$EXPECTED_SHA512" ]; then
  echo "sha512 mismatch for $TARBALL" >&2
  echo "expected: $EXPECTED_SHA512" >&2
  echo "actual:   $actual_sha512" >&2
  exit 1
fi

rm -rf "$WORK/extract"
mkdir -p "$WORK/extract"
tar -xzf "$WORK/cache/$TARBALL" -C "$WORK/extract"

echo "==> build iOS shim"
xcrun --sdk iphoneos clang \
  -target "arm64-apple-ios${IOS_MIN}" \
  -dynamiclib "$HERE/tools/opencode-ios-shim.c" \
  -o "$WORK/libopencode-ios-shim.dylib" \
  -install_name /var/jb/usr/lib/libopencode-ios-shim.dylib
ldid -S "$WORK/libopencode-ios-shim.dylib"

echo "==> restamp + patch upstream Mach-O"
vtool -set-build-version ios "$IOS_MIN" "$IOS_SDK_VERSION" -replace \
  -output "$WORK/opencode.ios" \
  "$WORK/extract/package/bin/opencode"
python3 "$HERE/tools/macho-opencode-ios-patch.py" "$WORK/opencode.ios" "$WORK/opencode"
chmod +x "$WORK/opencode"
ldid -S "$WORK/opencode"

cp "$WORK/opencode" "$OUT/opencode-ios-spike"
cp "$WORK/libopencode-ios-shim.dylib" "$OUT/libopencode-ios-shim.dylib"
echo "==> spike artifacts:"
ls -lh "$OUT/opencode-ios-spike" "$OUT/libopencode-ios-shim.dylib"

if [ "${SMOKE_DEVICE:-0}" = 1 ]; then
  SSH_OPTS=(-o BatchMode=yes -o IdentitiesOnly=yes -i "$HOME/.ssh/id_ed25519")
  DEVICE="${DEVICE:-root@MaxsiPad.local}"
  echo "==> on-device smoke test (required for package)"
  scp "${SSH_OPTS[@]}" "$OUT/opencode-ios-spike" "$OUT/libopencode-ios-shim.dylib" "$DEVICE:/var/jb/tmp/"
  if ! ssh "${SSH_OPTS[@]}" "$DEVICE" '
    set -e
    mkdir -p /var/jb/usr/lib
    cp /var/jb/tmp/libopencode-ios-shim.dylib /var/jb/usr/lib/libopencode-ios-shim.dylib
    chmod +x /var/jb/usr/lib/libopencode-ios-shim.dylib /var/jb/tmp/opencode-ios-spike
    /var/jb/tmp/opencode-ios-spike --version
  '; then
    echo "opencode iOS smoke failed; refusing to package" >&2
    echo "Current known blocker: SIGILL before main in upstream macOS Bun runtime on A10." >&2
    exit 1
  fi
else
  echo "==> skipping device smoke (set SMOKE_DEVICE=1 to enable)"
fi

if [ "${PACKAGE:-0}" != 1 ]; then
  echo "==> not packaging (set PACKAGE=1 and SMOKE_DEVICE=1)"
  exit 0
fi

echo "==> package opencode"
rm -rf "$WORK/pkg"
mkdir -p "$WORK/pkg/DEBIAN" "$WORK/pkg/var/jb/usr/bin" "$WORK/pkg/var/jb/usr/lib"
cp "$WORK/opencode" "$WORK/pkg/var/jb/usr/bin/opencode"
cp "$WORK/libopencode-ios-shim.dylib" "$WORK/pkg/var/jb/usr/lib/libopencode-ios-shim.dylib"
sed \
  -e "s/@DEB_VERSION@/$PKG_VERSION/g" \
  -e "s/@DEB_ARCH@/$ARCH/g" \
  -e "s/@OPENCODE_VERSION@/$VERSION/g" \
  "$HERE/build_info/opencode.control" > "$WORK/pkg/DEBIAN/control"
dpkg-deb -Zxz -b "$WORK/pkg" "$OUT/$PKG"
echo "==> built $OUT/$PKG"
