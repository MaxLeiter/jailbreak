#!/usr/bin/env bash
# Build the GNOME compatibility stub dylibs for a selected Xios target.
#
# Produces target-shaped runtime trees under:
#   linux-build/out/{gudev,udev,pwquality,gsound}-stub-tree/
#
# Then optionally assembles the xios-desktop-stublibs package from those trees.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
. "$HERE/target-lib.sh"

usage() {
  cat >&2 <<EOF
usage: $0 [target-id] [--package] [--dry-run] [--skip-image-build]

  target-id   Target descriptor from linux-build/targets/ (default: rootless-1900)
  --package   Run packages/xios-desktop-stublibs/build.sh after producers finish
  --dry-run   Print the docker commands without running them
  --skip-image-build
              Use an existing XIOS_PROC_IMAGE instead of running docker build
EOF
}

TARGET="${XIOS_TARGET:-rootless-1900}"
PACKAGE=0
DRY_RUN=0
SKIP_IMAGE_BUILD="${XIOS_SKIP_IMAGE_BUILD:-0}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --package) PACKAGE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --skip-image-build) SKIP_IMAGE_BUILD=1 ;;
    -h|--help) usage; exit 0 ;;
    *) TARGET="$1" ;;
  esac
  shift
done

xios_load_target "$TARGET"

IMAGE="${XIOS_PROC_IMAGE:-procursus-xbuild:bookworm-arm64}"
VOLUME="${PROCURSUS_VOL:-procursus-vol}"
SDK_SRC="${SDK_SRC:-$HOME/theos/sdks/iPhoneOS16.5.sdk}"
MACOS_SDK_SRC="${MACOS_SDK_SRC:-$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)}"
SCRIPTS=(
  build-gudev-stub.sh
  build-udev-stub.sh
  build-pwquality-stub.sh
  build-gsound-stub.sh
)

run_cmd() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

if [ "$DRY_RUN" != 1 ]; then
  command -v docker >/dev/null || { echo "docker not found" >&2; exit 1; }
  docker info >/dev/null 2>&1 || { echo "Docker daemon not running; start Docker Desktop first." >&2; exit 1; }
  [ -d "$SDK_SRC" ] || { echo "iOS SDK not found at $SDK_SRC (set SDK_SRC=...)." >&2; exit 1; }
  [ -n "$MACOS_SDK_SRC" ] && [ -d "$MACOS_SDK_SRC" ] || {
    echo "macOS SDK not found (set MACOS_SDK_SRC=...)." >&2
    exit 1
  }
fi

echo "==> target: $XIOS_TARGET_ID ($XIOS_MEMO_TARGET / CFVER $XIOS_MEMO_CFVER)"
if [ -n "$XIOS_PACKAGE_PATH_PREFIX" ]; then
  echo "==> output profile: $XIOS_PACKAGE_PATH_PREFIX$XIOS_SUBPREFIX/lib"
else
  echo "==> output profile: $XIOS_SUBPREFIX/lib"
fi

if [ "$DRY_RUN" != 1 ]; then
  echo "==> staging SDK into build context"
  mkdir -p sdk out
  if [ ! -d sdk/iPhoneOS.sdk ]; then
    rsync -a --delete "$SDK_SRC/" sdk/iPhoneOS.sdk/
  fi
  if [ ! -d sdk/MacOSX.sdk ]; then
    rsync -a --delete "$MACOS_SDK_SRC/" sdk/MacOSX.sdk/
  fi

  if [ "$SKIP_IMAGE_BUILD" != 1 ]; then
    echo "==> ensuring toolchain image exists"
  else
    echo "==> skipping image build; using existing $IMAGE"
  fi
fi
if [ "$SKIP_IMAGE_BUILD" != 1 ]; then
  run_cmd docker build --platform linux/arm64 -t "$IMAGE" .
fi

echo "==> checking target sysroot prerequisites"
run_cmd docker run --rm --platform linux/arm64 \
  -e XIOS_TARGET_ID \
  -e XIOS_MEMO_TARGET \
  -e XIOS_MEMO_CFVER \
  -e XIOS_SUBPREFIX \
  -e XIOS_PACKAGE_PATH_PREFIX \
  -v "$VOLUME:/work/Procursus" \
  --entrypoint bash "$IMAGE" -lc '
set -euo pipefail
sysroot="/work/Procursus/build_base/$XIOS_MEMO_TARGET/$XIOS_MEMO_CFVER$XIOS_PACKAGE_PATH_PREFIX$XIOS_SUBPREFIX"
missing=0
for path in \
  include/glib-2.0 \
  lib/pkgconfig/glib-2.0.pc \
  lib/pkgconfig/gio-2.0.pc \
  lib/pkgconfig/gobject-2.0.pc \
  lib/libglib-2.0.0.dylib \
  lib/libgio-2.0.0.dylib \
  lib/libgobject-2.0.0.dylib
do
  if [ ! -e "$sysroot/$path" ]; then
    echo "missing: $sysroot/$path" >&2
    missing=1
  fi
done
if [ "$missing" = 1 ]; then
  echo "Target sysroot is not ready for $XIOS_TARGET_ID." >&2
  echo "Build the missing Procursus deps first, for example:" >&2
  echo "  bash linux-build/build-procursus-target.sh $XIOS_TARGET_ID --skip-image-build glib2.0-package" >&2
  exit 1
fi
echo "   glib sysroot ready: $sysroot"
'

for script in "${SCRIPTS[@]}"; do
  src="${script#build-}"
  src="${src%-stub.sh}-stub"
  echo "==> $script"
  run_cmd docker run --rm --platform linux/arm64 \
    -e XIOS_TARGET_ID \
    -e XIOS_MEMO_TARGET \
    -e XIOS_MEMO_CFVER \
    -e XIOS_PREFIX \
    -e XIOS_SUBPREFIX \
    -e XIOS_PACKAGE_PATH_PREFIX \
    -e XIOS_DEFAULT_MIN_IOS \
    -e PATH="/root/cctools/bin:/work/Procursus/build_tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -e LD_LIBRARY_PATH="/root/cctools/lib" \
    -v "$VOLUME:/work/Procursus" \
    -v "$HERE/$src:/work/$src:ro" \
    -v "$HERE/$script:/work/$script:ro" \
    -v "$HERE/out:/out" \
    --entrypoint bash "$IMAGE" "/work/$script"
done

if [ "$PACKAGE" = 1 ]; then
  echo "==> assembling xios-desktop-stublibs package"
  run_cmd bash "$HERE/../packages/xios-desktop-stublibs/build.sh" "$XIOS_TARGET_ID"
else
  echo "==> done. Assemble with:"
  echo "    bash packages/xios-desktop-stublibs/build.sh $XIOS_TARGET_ID"
fi
