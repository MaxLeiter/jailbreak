#!/usr/bin/env bash
# Mac-side runner for the Bun/OpenCode iOS bring-up probes.
set -euo pipefail
cd "$(dirname "$0")"

IMAGE="${IMAGE:-procursus-xbuild:bookworm-arm64}"
SDK_SRC="${SDK_SRC:-$HOME/theos/sdks/iPhoneOS16.5.sdk}"
MODE="${1:-all}"

command -v docker >/dev/null || { echo "docker not found"; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker daemon not running - start Docker Desktop first."; exit 1; }
[ -d "$SDK_SRC" ] || { echo "iOS SDK not found at $SDK_SRC (set SDK_SRC=...)."; exit 1; }

echo "==> staging SDK into build context (once)"
mkdir -p sdk out
if [ ! -d sdk/iPhoneOS.sdk ]; then
  rsync -a --delete "$SDK_SRC/" sdk/iPhoneOS.sdk/
fi

echo "==> building/reusing toolchain image"
docker build --platform linux/arm64 -t "$IMAGE" .

echo "==> running Bun spike mode: $MODE"
docker run --rm --platform linux/arm64 \
  -v "$PWD/build-bun.sh:/work/build-bun.sh:ro" \
  -v "$PWD/out:/out" \
  "$IMAGE" /work/build-bun.sh "$MODE"

if [ "${DEPLOY:-0}" = 1 ]; then
  SSH_OPTS=(-o BatchMode=yes -o IdentitiesOnly=yes -i "$HOME/.ssh/id_ed25519")
  DEVICE="${DEVICE:-root@MaxsiPad.local}"

  echo "==> deploying bun-preflight to $DEVICE"
  scp "${SSH_OPTS[@]}" out/bun-preflight "$DEVICE:/var/jb/tmp/bun-preflight"
  ssh "${SSH_OPTS[@]}" "$DEVICE" 'chmod +x /var/jb/tmp/bun-preflight; /var/jb/tmp/bun-preflight'

  if [ -f out/bun-darwin-arm64-upstream ]; then
    echo "==> deploying upstream Bun probe to $DEVICE (expected to fail on iOS)"
    scp "${SSH_OPTS[@]}" out/bun-darwin-arm64-upstream "$DEVICE:/var/jb/tmp/bun-upstream-probe"
    ssh "${SSH_OPTS[@]}" "$DEVICE" 'chmod +x /var/jb/tmp/bun-upstream-probe; ldid -S /var/jb/tmp/bun-upstream-probe; /var/jb/tmp/bun-upstream-probe --version' || true
  fi
fi
