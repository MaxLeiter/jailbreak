#!/usr/bin/env bash
# Ladybird-on-iOS source patch series (idempotent).
#   usage: ladybird-m0-patches.sh <ladybird-source-dir>
#
# Engine-tree edits (NOT dependency recipes) needed for the iOS cross build. CMake-level iOS is
# asserted by the toolchain file (`set(IOS TRUE)`), so `if (IOS)` is usable in any CMake reached
# during configure. Source-level iOS is `__IOS__` (injected by the compiler wrapper) -> AK_OS_IOS.
#
# Rebased 2026-10 onto upstream master b9c913c0 (see x11/docs/ladybird-rebase-2026-10.md).
# The series are plain `patch -p1` diffs; each patch is applied if it applies forward, skipped if it
# is already applied (reverse dry-run succeeds), and a failure aborts the build.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${1:?usage: ladybird-m0-patches.sh <ladybird-source-dir>}"
cd "$SRC"

say() { echo "  [m0-patch] $*"; }

APPLIED_LIST="$SRC/.git/lb-applied-patches"
touch "$APPLIED_LIST"
apply_series() {
  local patch_dir="$1" patch_name patch_file
  [ -f "$patch_dir/series" ] || return 0
  while IFS= read -r patch_name; do
    patch_name="${patch_name%%#*}"
    patch_name="${patch_name## }"
    patch_name="${patch_name%% }"
    [ -n "$patch_name" ] || continue
    patch_file="$patch_dir/$patch_name"
    # A later patch can touch the same lines as an earlier one, so "already applied" cannot be
    # detected by a reverse dry-run. Applied patches are recorded by name in the tree's .git dir.
    if grep -qxF "$patch_name" "$APPLIED_LIST"; then
      say "$patch_name already applied (recorded)"
    elif patch -p1 --dry-run -f < "$patch_file" >/dev/null 2>&1; then
      patch -p1 --no-backup-if-mismatch < "$patch_file" >/dev/null
      echo "$patch_name" >> "$APPLIED_LIST"
      say "applied $patch_name"
    else
      echo "failed to apply $patch_file (not recorded as applied)" >&2
      return 1
    fi
  done < "$patch_dir/series"
}

# Common patches needed by both headless and app builds.
apply_series "$SCRIPT_DIR/patches-m0"

# =============================================================================================
# APP-BUILD MODE (LB_APP_BUILD=1 only). The interactive UIKit .app uses the NORMAL compositor
# paint cycle, so the Compositor is re-enabled as a helper, the UIKit frontend is wired into the
# build, and the Mach IPC / IOSurface transport is enabled for iOS. Guarded by LB_APP_BUILD so the
# headless build only applies patches-m0.
# =============================================================================================
if [ "${LB_APP_BUILD:-0}" = "1" ]; then
  say "APP-BUILD MODE: re-enabling Compositor + wiring UI/iOS"
  apply_series "$SCRIPT_DIR/patches"
fi

echo "  [m0-patch] all patches applied."
