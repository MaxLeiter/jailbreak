#!/usr/bin/env bash
# Host entry point for the standalone Xios-owned GIMP stack.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
IMAGE="${XIOS_GIMP_IMAGE:-procursus-xbuild:bookworm-arm64}"
VOLUME="${XIOS_GIMP_VOLUME:-xios-gimp-build}"
CPUS="${XIOS_BUILD_CPUS:-4}"

docker volume inspect "$VOLUME" >/dev/null 2>&1 || docker volume create "$VOLUME"
mkdir -p "$HERE/out"

docker run --rm --platform linux/arm64 --cpus="$CPUS" \
  --entrypoint /bin/bash \
  -v "$VOLUME:/work" \
  -v "$HERE/gimp:/scripts:ro" \
  -v "$HERE/tools:/xios-tools:ro" \
  -v "$ROOT/ports:/ports:ro" \
  -v "$HERE/out:/out" \
  -v "$REPO_ROOT/repo/debs:/repo-debs:ro" \
  "$IMAGE" /scripts/build.sh

bash "$ROOT/packages/gimp-stack/package.sh"
