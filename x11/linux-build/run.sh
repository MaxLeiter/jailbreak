#!/usr/bin/env bash
# Runs on the MAC. Builds the Procursus cross-toolchain image and uses it to
# produce the fixed tigervnc .deb for the iPad. Requires Docker running.
#
#   bash x11/linux-build/run.sh
#
# Output: x11/linux-build/out/tigervnc-*_iphoneos-arm.deb
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
_x="$HERE"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"
. "$HERE/target-lib.sh"

xios_load_target "${1:-${XIOS_TARGET:-rootless-1900}}"
echo "==> target: $XIOS_TARGET_ID ($XIOS_MEMO_TARGET / CFVER $XIOS_MEMO_CFVER)"
if [ "$XIOS_TARGET_ID" != "rootless-1900" ]; then
  echo "ERROR: linux-build/run.sh still drives rootless-only follow-up steps; use rootless-1900 for now." >&2
  echo "       Rootful support starts with target-aware package generation and smoke tests." >&2
  exit 2
fi

IMAGE="procursus-xbuild:bookworm-arm64"
# Named volume holding the cloned + already-built Procursus tree. Persisting it
# across runs means the ~50 deps (mesa, libx11, ...) keep their .build_complete
# markers and are reused; only tigervnc rebuilds. First run populates it.
VOLUME="${PROCURSUS_VOL:-procursus-vol}"
SDK_SRC="${SDK_SRC:-$HOME/theos/sdks/iPhoneOS16.5.sdk}"

command -v docker >/dev/null || { echo "docker not found"; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker daemon not running — start Docker Desktop first."; exit 1; }
[ -d "$SDK_SRC" ] || { echo "iOS SDK not found at $SDK_SRC (set SDK_SRC=...)."; exit 1; }

echo "==> staging SDK into build context (once)"
mkdir -p sdk out
if [ ! -d sdk/iPhoneOS.sdk ]; then
  rsync -a --delete "$SDK_SRC/" sdk/iPhoneOS.sdk/
fi

echo "==> building toolchain image (cached after first run; first build is slow)"
docker build --platform linux/arm64 -t "$IMAGE" .

echo "==> building tigervnc inside the container (reusing volume $VOLUME)"
docker run --rm --platform linux/arm64 \
  -e XIOS_TARGET_ID \
  -e XIOS_MEMO_TARGET \
  -e XIOS_MEMO_CFVER \
  -e XIOS_PREFIX \
  -e XIOS_SUBPREFIX \
  -v "$VOLUME:/work/Procursus" \
  -v "$PWD/target-env.sh:/work/target-env.sh:ro" \
  -v "$PWD/build.sh:/work/build.sh:ro" \
  -v "$PWD/patches:/work/patches:ro" \
  -v "$HERE/../ports:/work/ports:ro" \
  -v "$PWD/out:/out" \
  "$IMAGE" /work/build.sh

echo "==> building Xios audio support"
docker run --rm --platform linux/arm64 \
  -e XIOS_MEMO_TARGET -e XIOS_MEMO_CFVER -e XIOS_PREFIX -e XIOS_SUBPREFIX \
  -v "$PWD/target-env.sh:/work/target-env.sh:ro" \
  -v "$PWD/audio:/work/audio:ro" \
  -v "$PWD/out:/out" \
  "$IMAGE" /work/audio/build-audio.sh

# The in-container ldid does not emit DER-encoded entitlements, which iOS 15+/16 AMFI
# requires to honor iokit-user-client-class — IOSurfaceCreate() returns NULL otherwise
# (the XML entitlements still read fine via `ldid -e`, so this is silent). The Mac's
# ldid does emit DER, so re-sign Xios here with the plist build.sh produced.
if [ -f out/Xios ]; then
  # This re-sign is correctness-critical (without DER entitlements IOSurfaceCreate
  # returns NULL on-device), so fail loudly rather than shipping a broken binary.
  command -v ldid >/dev/null || { echo "ERROR: ldid not found — cannot DER-sign Xios; 'brew install ldid'"; exit 1; }
  [ -f out/xios-ent.xml ] || { echo "ERROR: out/xios-ent.xml missing (build.sh should have written it)"; exit 1; }
  echo "==> re-signing Xios with the Mac ldid (DER entitlements, for IOKit/IOSurface)"
  xsign out/Xios out/xios-ent.xml \
    platform-application com.apple.private.skip-library-validation task_for_pid-allow \
    IOSurfaceRootUserClient
fi

echo "==> artifacts:"
ls -l out/
