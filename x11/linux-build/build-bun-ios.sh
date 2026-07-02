#!/usr/bin/env bash
# Reproducible Bun iPhoneOS/A10 source-build experiment for OpenCode.
#
# This is intentionally a source-build path. The upstream macOS standalone
# runtime crashes with SIGILL on iPad7,12/A10 because it is built for newer
# Apple Silicon instructions. This script pins Bun, applies the local iOS/A10
# build-system patch, and asks Bun's own build graph to produce an iPhoneOS
# runtime with local WebKit/JSC.
set -euo pipefail
umask 022
export LC_ALL=C
export TZ=UTC

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$HERE/out}"
WORK="${WORK:-$OUT/bun-ios-work}"
LOCK="${BUN_IOS_LOCK:-$HERE/build_info/bun-ios.lock}"
PATCH="${BUN_IOS_PATCH:-$HERE/patches/bun/0001-add-iphoneos-a10-target.patch}"
WEBKIT_PATCH_DIR="${BUN_WEBKIT_PATCH_DIR:-$HERE/patches/bun-webkit}"
BUILD_DIR="${BUILD_DIR:-build/ios-a10}"
CONTROL="${BUN_IOS_CONTROL:-$HERE/build_info/bun.control}"
BUN_VERSION="${BUN_VERSION:-1.4.0~canary.1+git5b55beb711+ios0.4}"
ARCH="${ARCH:-iphoneos-arm64}"
PKG="bun_${BUN_VERSION}_${ARCH}.deb"

[ -f "$LOCK" ] || { echo "Bun iOS lock file not found: $LOCK" >&2; exit 1; }
[ -f "$PATCH" ] || { echo "Bun iOS patch not found: $PATCH" >&2; exit 1; }
[ -f "$CONTROL" ] || { echo "Bun package control file not found: $CONTROL" >&2; exit 1; }
# shellcheck disable=SC1090
. "$LOCK"

need() { command -v "$1" >/dev/null || { echo "$1 not found" >&2; exit 1; }; }
need git
need bun
need xcrun
need ninja
need cmake

build_deb() {
  local stage="$1"
  local deb="$2"
  if command -v dpkg-deb >/dev/null && dpkg-deb --version >/dev/null 2>&1; then
    dpkg-deb -Zxz -b "$stage" "$deb"
    return
  fi
  need docker
  docker run --rm \
    -v "$stage:/pkg:ro" \
    -v "$(dirname "$deb"):/out" \
    debian:bookworm \
    dpkg-deb -Zxz -b /pkg "/out/$(basename "$deb")"
}

mkdir -p "$WORK" "$OUT"
SRC="$WORK/bun"

if [ ! -d "$SRC/.git" ]; then
  git clone "$BUN_GIT_REPO" "$SRC"
fi
git -C "$SRC" fetch --quiet origin "$BUN_GIT_COMMIT"
git -C "$SRC" checkout --quiet "$BUN_GIT_COMMIT"
git -C "$SRC" reset --quiet --hard "$BUN_GIT_COMMIT"
git -C "$SRC" clean -fd --quiet
git -C "$SRC" apply "$PATCH"

# TinyCC iOS run-memory patch: bun's build graph (scripts/build/deps/tinycc.ts)
# applies it from $SRC/patches/tinycc/ when cfg.ios. It lives in our tree, so
# stage it into the (reset+cleaned) checkout after the main patch is applied.
TINYCC_IOS_PATCH="${TINYCC_IOS_PATCH:-$HERE/patches/tinycc/tccrun-ios-mmap.patch}"
[ -f "$TINYCC_IOS_PATCH" ] || { echo "TinyCC iOS patch not found: $TINYCC_IOS_PATCH" >&2; exit 1; }
install -d "$SRC/patches/tinycc"
cp "$TINYCC_IOS_PATCH" "$SRC/patches/tinycc/tccrun-ios-mmap.patch"

LLVM_PREFIX="${LLVM_PREFIX:-/opt/homebrew/opt/llvm@21}"
if [ -x "$LLVM_PREFIX/bin/clang" ]; then
  export PATH="$LLVM_PREFIX/bin:$PATH"
  export CC="$LLVM_PREFIX/bin/clang"
  export CXX="$LLVM_PREFIX/bin/clang++"
  export AR="$LLVM_PREFIX/bin/llvm-ar"
  export RANLIB="$LLVM_PREFIX/bin/llvm-ranlib"
  export LD="$LLVM_PREFIX/bin/ld.lld"
fi

IPHONEOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
export SDKROOT="$IPHONEOS_SDK"

WEBKIT_PATH="${BUN_WEBKIT_PATH:-$WORK/WebKit}"
if [ ! -d "$WEBKIT_PATH/.git" ]; then
  echo "==> clone pinned WebKit source"
  git clone --filter=blob:none "$BUN_WEBKIT_REPO" "$WEBKIT_PATH"
fi
git -C "$WEBKIT_PATH" fetch --quiet origin "$BUN_WEBKIT_COMMIT"
git -C "$WEBKIT_PATH" checkout --quiet "$BUN_WEBKIT_COMMIT"
git -C "$WEBKIT_PATH" reset --quiet --hard "$BUN_WEBKIT_COMMIT"
for patch in "$WEBKIT_PATCH_DIR"/*.patch; do
  [ -e "$patch" ] || continue
  git -C "$WEBKIT_PATH" apply "$patch"
done
export BUN_WEBKIT_PATH="$WEBKIT_PATH"

echo "==> configure/build Bun for iPhoneOS A10"
CONFIGURE_ONLY=0
for arg in "$@"; do
  if [ "$arg" = "--configure-only" ]; then
    CONFIGURE_ONLY=1
  fi
done
(
  cd "$SRC"
  set +e
  bun scripts/build.ts \
    --profile=release \
    --os=darwin \
    --arch=aarch64 \
    --apple-platform=ios \
    --webkit=local \
    --asan=off \
    --assertions=off \
    --lto=off \
    --osx-deployment-target="${IOS_MIN:-16.0}" \
    --build-dir="$BUILD_DIR" \
    "$@"
  status=$?
  set -e
  if [ "$status" -ne 0 ] && [ ! -x "$BUILD_DIR/bun-profile" ] && [ ! -x "$BUILD_DIR/bun" ]; then
    exit "$status"
  fi
  if [ "$status" -ne 0 ]; then
    echo "==> build returned $status after link; continuing with linked iOS binary"
  fi
)

if [ "$CONFIGURE_ONLY" = 1 ]; then
  echo "==> configured $SRC/$BUILD_DIR"
  exit 0
fi

BIN="$SRC/$BUILD_DIR/bun"
if [ ! -x "$BIN" ]; then
  BIN="$SRC/$BUILD_DIR/bun-profile"
fi
if [ -x "$BIN" ]; then
  cp "$BIN" "$OUT/bun-ios-a10"
  echo "==> built $OUT/bun-ios-a10"
else
  echo "Bun iOS build finished without expected binary: $BIN" >&2
  exit 1
fi

if [ "${PACKAGE:-0}" = 1 ]; then
  echo "==> package Bun for rootless iOS"
  rm -rf "$WORK/pkg"
  mkdir -p "$WORK/pkg/DEBIAN" "$WORK/pkg/var/jb/usr/bin" "$WORK/pkg/var/jb/usr/libexec/bun-ios"
  cp "$OUT/bun-ios-a10" "$WORK/pkg/var/jb/usr/libexec/bun-ios/bun"
  chmod 0755 "$WORK/pkg/var/jb/usr/libexec/bun-ios/bun"
  if command -v ldid >/dev/null; then
    ldid -S "$WORK/pkg/var/jb/usr/libexec/bun-ios/bun" || true
  fi
  cat > "$WORK/pkg/var/jb/usr/bin/bun" <<'EOF'
#!/var/jb/usr/bin/sh
export GIGACAGE_ENABLED="${GIGACAGE_ENABLED:-0}"
exec /var/jb/usr/libexec/bun-ios/bun "$@"
EOF
  chmod 0755 "$WORK/pkg/var/jb/usr/bin/bun"
  sed \
    -e "s/@DEB_VERSION@/$BUN_VERSION/g" \
    -e "s/@DEB_ARCH@/$ARCH/g" \
    -e "s/@BUN_COMMIT@/$BUN_GIT_COMMIT/g" \
    "$CONTROL" > "$WORK/pkg/DEBIAN/control"
  build_deb "$WORK/pkg" "$OUT/$PKG"
  echo "==> built $OUT/$PKG"
fi
