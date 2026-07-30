#!/usr/bin/env bash
# Register the repo/Packages merge driver in this clone.
#
# .gitattributes maps repo/Packages to merge=aptindex, but git deliberately
# refuses to learn a driver's command line from a tracked file (it would be
# arbitrary code execution on clone), so each clone opts in once:
#
#   bin/setup-git-merge-driver.sh
#
# Worktrees share the parent clone's config, so running it once in the main
# checkout covers every worktree made from it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="$REPO_ROOT/bin/lib/merge-packages.py"

[ -x "$DRIVER" ] || chmod +x "$DRIVER"

git -C "$REPO_ROOT" config merge.aptindex.name \
  "APT Packages index merge (newer version per package wins)"
git -C "$REPO_ROOT" config merge.aptindex.driver \
  "python3 '$DRIVER' %O %A %B %P"

echo "==> registered merge.aptindex in $(git -C "$REPO_ROOT" rev-parse --git-common-dir)/config"
echo "    repo/Packages now merges structurally; rerun this if you re-clone."
