#!/usr/bin/env bash
# Repack the staged KDE 6.7 debs with the device-run-1 packaging fixes (no rebuild, no build volume).
#
#   repack-kde67-run1.sh <dir holding the staged debs> [out dir]
#
# The staged debs are listed in KDE67-STAGED.txt in the claude/kde-67 worktree (x11/linux-build/out/).
# Output defaults to x11/linux-build/out/kde67-fixed/. Only the repo (read-only) and the two dirs
# are mounted; no Docker volume is touched. Details: tools/repack-kde67-run1.py.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
X11="$(cd "$HERE/../.." && pwd)"
STAGED="$(cd "${1:?usage: repack-kde67-run1.sh <staged deb dir> [out dir]}" && pwd)"
OUT="${2:-$X11/linux-build/out/kde67-fixed}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
IMG="${XLIB_XBUILD_IMAGE:-procursus-xbuild:bookworm-arm64}"

docker run --rm --platform linux/arm64 \
  -v "$STAGED:/staged:ro" -v "$X11:/repo/x11:ro" -v "$OUT:/out" \
  "$IMG" -c "python3 /repo/x11/linux-build/tools/repack-kde67-run1.py"
