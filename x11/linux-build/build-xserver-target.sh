#!/usr/bin/env bash
# Build the patched X server artifacts (Xvfb/Xios source tree) for a target descriptor.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
. "$HERE/target-lib.sh"

usage() {
  cat >&2 <<EOF
usage: $0 [target-id] [--package-xvfb] [--package-xios] [--dry-run] [--skip-image-build]

  target-id            Target descriptor from linux-build/targets/ (default: rootless-1900)
  --package-xvfb       Assemble packages/x11-xvfb/build.sh after Xvfb is built
  --package-xios       Assemble packages/xios-server/build.sh after Xios is built
  --dry-run            Print docker commands without running them
  --skip-image-build   Use an existing XIOS_PROC_IMAGE instead of running docker build
EOF
}

TARGET="${XIOS_TARGET:-rootless-1900}"
PACKAGE_XVFB=0
PACKAGE_XIOS=0
DRY_RUN=0
SKIP_IMAGE_BUILD="${XIOS_SKIP_IMAGE_BUILD:-0}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --package-xvfb) PACKAGE_XVFB=1 ;;
    --package-xios) PACKAGE_XIOS=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --skip-image-build) SKIP_IMAGE_BUILD=1 ;;
    -h|--help) usage; exit 0 ;;
    *) TARGET="$1" ;;
  esac
  shift
done

xios_load_target "$TARGET"

IMAGE="${XIOS_PROC_IMAGE:-procursus-xbuild:bookworm-arm64}"
# Keep the rootless volume exactly where it was; give any other profile its own,
# so a rootful bootstrap does not double the disk on the volume that holds the
# working rootless tree (and its ~50 .build_complete markers).
if [ "$XIOS_TARGET_ID" = "rootless-1900" ]; then
  VOLUME="${PROCURSUS_VOL:-procursus-vol}"
else
  VOLUME="${PROCURSUS_VOL:-procursus-vol-$XIOS_REPO_PROFILE}"
fi
SDK_SRC="${SDK_SRC:-$HOME/theos/sdks/iPhoneOS16.5.sdk}"
MACOS_SDK_SRC="${MACOS_SDK_SRC:-$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)}"
TARGET_OUT="$HERE/out/targets/$XIOS_TARGET_ID"

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
echo "==> artifact out: $TARGET_OUT"

if [ "$DRY_RUN" != 1 ]; then
  echo "==> staging SDK into build context"
  mkdir -p sdk "$TARGET_OUT"
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

run_cmd docker run --rm --platform linux/arm64 \
  -e XIOS_TARGET_ID \
  -e XIOS_MEMO_TARGET \
  -e XIOS_MEMO_CFVER \
  -e XIOS_PREFIX \
  -e XIOS_SUBPREFIX \
  -e XIOS_DEB_ARCH \
  -v "$VOLUME:/work/Procursus" \
  -v "$HERE/target-env.sh:/work/target-env.sh:ro" \
  -v "$HERE/procursus-common-edits.py:/work/procursus-common-edits.py:ro" \
  -v "$HERE/build.sh:/work/build.sh:ro" \
  -v "$HERE/patches:/work/patches:ro" \
  -v "$TARGET_OUT:/out" \
  "$IMAGE" /work/build.sh

if [ "$DRY_RUN" != 1 ]; then
  if [ -f "$TARGET_OUT/Xvfb" ]; then
    echo "==> Xvfb built: $TARGET_OUT/Xvfb"
  else
    echo "ERROR: Xvfb was not produced at $TARGET_OUT/Xvfb" >&2
    exit 1
  fi
fi

if [ "$PACKAGE_XVFB" = 1 ]; then
  run_cmd bash "$HERE/../packages/x11-xvfb/build.sh" "$XIOS_TARGET_ID"
fi
if [ "$PACKAGE_XIOS" = 1 ]; then
  run_cmd bash "$HERE/../packages/xios-server/build.sh" "$XIOS_TARGET_ID"
fi
if [ "$PACKAGE_XVFB" != 1 ] && [ "$PACKAGE_XIOS" != 1 ]; then
  echo "==> package with:"
  echo "    bash packages/x11-xvfb/build.sh $XIOS_TARGET_ID"
  echo "    bash packages/xios-server/build.sh $XIOS_TARGET_ID"
fi
