#!/usr/bin/env bash
# Run one of the container-side build scripts against a target descriptor.
#
#   linux-build/run-target-script.sh [target-id] <script.sh> [-- extra docker args]
#
# The container scripts (build-wayland.sh, build-gtk.sh, build-kwin.sh, ...) are
# invoked by hand-written `docker run` lines copied out of their header comments.
# Those lines predate the target matrix, so they mount neither target-env.sh nor
# procursus-common-edits.py and pass no XIOS_* through -- meaning every one of
# them silently builds rootless no matter which target you meant.
#
# This wrapper is the one place that knows the standard mount set and env, so a
# target selection actually reaches the script. Volumes follow the same rule as
# the other wrappers: rootless keeps its historical name, other profiles get
# their own, so a rootful bootstrap never lands in the working rootless tree.
#
#   bash linux-build/run-target-script.sh rootful-1900 build-wayland.sh
#   PROCURSUS_VOL=procursus-vol-wayland bash linux-build/run-target-script.sh build-wayland.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
X11DIR="$(cd "$HERE/.." && pwd)"
. "$HERE/target-lib.sh"

TARGET="${XIOS_TARGET:-rootless-1900}"
SCRIPT=""
EXTRA=()
DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --) shift; EXTRA+=("$@"); break ;;
    -h|--help) sed -n '2,18p' "$0" >&2; exit 0 ;;
    *)
      if [ -f "$HERE/targets/$1.env" ]; then TARGET="$1"
      else SCRIPT="$1"
      fi
      ;;
  esac
  shift
done

[ -n "$SCRIPT" ] || { echo "usage: $0 [target-id] <script.sh>" >&2; exit 2; }

# Accept a bare name, a linux-build-relative path, or a path from the repo root.
for cand in "$SCRIPT" "$HERE/$SCRIPT" "$X11DIR/$SCRIPT"; do
  [ -f "$cand" ] && { SCRIPT_PATH="$(cd "$(dirname "$cand")" && pwd)/$(basename "$cand")"; break; }
done
[ -n "${SCRIPT_PATH:-}" ] || { echo "script not found: $SCRIPT" >&2; exit 2; }

xios_load_target "$TARGET"

IMAGE="${XIOS_PROC_IMAGE:-procursus-xbuild:bookworm-arm64}"
if [ "$XIOS_TARGET_ID" = "rootless-1900" ]; then
  VOLUME="${PROCURSUS_VOL:-procursus-vol}"
else
  VOLUME="${PROCURSUS_VOL:-procursus-vol-$XIOS_REPO_PROFILE}"
fi
OUT="${XIOS_OUT:-$HERE/out}"
if [ "$XIOS_TARGET_ID" != "rootless-1900" ]; then
  OUT="$OUT/targets/$XIOS_TARGET_ID"
fi
mkdir -p "$OUT"

echo "==> target: $XIOS_TARGET_ID ($XIOS_MEMO_TARGET / CFVER $XIOS_MEMO_CFVER / prefix ${XIOS_PREFIX:-/})"
echo "==> script: $SCRIPT_PATH"
echo "==> volume: $VOLUME"
echo "==> out:    $OUT"
[ -n "${JOBS:-}" ] && echo "==> jobs:   $JOBS"

# The container scripts document rebuild and staging knobs (FORCE_REBUILD,
# SKIP_GAME_DEP_STAGING, ...) but they are read inside the container, so they
# have to be forwarded explicitly. Without this a "forced" rebuild silently
# reuses the previous tree. XIOS_ENV_PASS carries any additional names.
PASS_ENV=(FORCE_REBUILD FORCE_GAME_DEPS_REBUILD FORCE_GAME_DEPS_STAGE
  FORCE_SDL_REBUILD FORCE_SDL_SMOKE_REBUILD SKIP_GAME_DEP_STAGING)
for name in ${XIOS_ENV_PASS:-}; do PASS_ENV+=("$name"); done

cmd=(docker run --rm --platform linux/arm64
  -e XIOS_TARGET_ID -e XIOS_MEMO_TARGET -e XIOS_MEMO_CFVER -e XIOS_PREFIX
  -e XIOS_SUBPREFIX -e XIOS_DEB_ARCH -e JOBS -e TARGETS -e ICU_VERSION -e MUTTER_CLEAN
)
for name in "${PASS_ENV[@]}"; do
  [ -n "${!name:-}" ] && cmd+=(-e "$name")
done
cmd+=(
  -v "$VOLUME:/work/Procursus"
  -v "$HERE/target-env.sh:/work/target-env.sh:ro"
  -v "$HERE/procursus-common-edits.py:/work/procursus-common-edits.py:ro"
  -v "$X11DIR:/work/x11:ro"
  -v "$HERE/recipes:/work/recipes:ro"
  -v "$HERE/build_info:/work/build_info:ro"
  -v "$HERE/patches:/work/patches:ro"
  -v "$X11DIR/ports:/work/ports:ro"
  -v "$SCRIPT_PATH:/work/$(basename "$SCRIPT_PATH"):ro"
  -v "$OUT:/out"
)
if [ "${#EXTRA[@]}" -gt 0 ]; then
  cmd+=("${EXTRA[@]}")
fi
cmd+=("$IMAGE" "/work/$(basename "$SCRIPT_PATH")")

if [ "$DRY_RUN" = 1 ]; then
  printf '+'; printf ' %q' "${cmd[@]}"; printf '\n'
  exit 0
fi
"${cmd[@]}"
