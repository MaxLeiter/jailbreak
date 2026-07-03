#!/usr/bin/env bash
# Host wrapper for the Xios native camera/microphone bridge package.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${XIOS_PROC_IMAGE:-procursus-xbuild:bookworm-arm64}"

docker run --rm --platform linux/arm64 \
    -v "$ROOT/linux-build/media:/work/media:ro" \
    -v "$ROOT/linux-build/out:/out" \
    --entrypoint bash "$IMAGE" /work/media/build-media.sh
