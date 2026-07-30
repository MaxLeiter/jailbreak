#!/usr/bin/env bash
# One-time per-clone setup. Run this after cloning:
#
#   bin/setup-repo-guards.sh
#
# Installs two things that cannot ship in tracked files, both of which prevent
# silent data loss:
#
#   1. The repo/Packages merge driver. .gitattributes maps the file to
#      merge=aptindex, but git deliberately refuses to learn a driver's command
#      line from a tracked file (that would be arbitrary code execution on
#      clone), so every clone opts in explicitly.
#
#   2. The Claude Code PreToolUse guard (bin/lib/guard-repo-ops.sh), which blocks
#      a bare sync-packages-to-repo.py and hand-edits of generated repo output.
#      Hook config lives in .claude/settings.json, which is gitignored.
#
# Both are idempotent, so rerunning is always safe. Note the two halves have
# different scope: git config lives in the shared git dir, so the merge driver is
# registered once for the clone and every worktree made from it. .claude/ is a
# working-tree path, so each worktree needs its own hook registration -- run this
# again after `git worktree add`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVER="$REPO_ROOT/bin/lib/merge-packages.py"
GUARD="$REPO_ROOT/bin/lib/guard-repo-ops.sh"
SETTINGS="$REPO_ROOT/.claude/settings.json"

chmod +x "$DRIVER" "$GUARD" 2>/dev/null || true

# ── 1. repo/Packages merge driver ────────────────────────────────────────────
git -C "$REPO_ROOT" config merge.aptindex.name \
  "APT Packages index merge (newer version per package wins)"
git -C "$REPO_ROOT" config merge.aptindex.driver \
  "python3 '$DRIVER' %O %A %B %P"
echo "==> merge.aptindex registered in $(git -C "$REPO_ROOT" rev-parse --git-common-dir)/config"

# ── 2. Claude Code PreToolUse guard ──────────────────────────────────────────
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

GUARD="$GUARD" SETTINGS="$SETTINGS" python3 <<'PY'
import json, os

settings_path = os.environ["SETTINGS"]
guard = os.environ["GUARD"]

with open(settings_path) as fh:
    text = fh.read().strip() or "{}"
settings = json.loads(text)

entries = settings.setdefault("hooks", {}).setdefault("PreToolUse", [])

# Replace any previous wiring of this guard rather than stacking duplicates.
def mentions_guard(entry):
    return any("guard-repo-ops.sh" in h.get("command", "")
               for h in entry.get("hooks", []))

entries[:] = [e for e in entries if not mentions_guard(e)]
entries.append({
    "matcher": "Bash|Edit|Write|NotebookEdit",
    "hooks": [{"type": "command", "command": f"bash '{guard}'"}],
})

with open(settings_path, "w") as fh:
    json.dump(settings, fh, indent=2)
    fh.write("\n")
print(f"==> PreToolUse guard registered in {settings_path}")
PY

echo "==> done. Restart Claude Code (or reopen the session) for the hook to load."
