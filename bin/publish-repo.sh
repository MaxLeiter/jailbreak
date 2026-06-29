#!/usr/bin/env bash
# Regenerate the APT repo index and deploy it to Vercel (repo.maxleiter.com).
#
# To publish a tweak: build it, copy its .deb into repo/debs/, then run this.
#   bin/build.sh tweaks/<Name>
#   cp tweaks/<Name>/packages/*.deb repo/debs/
#   bin/publish-repo.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> Regenerating index (Packages / Release / depictions / assets)"
# Use the Pillow venv if present (for icon/banner generation), else system python.
PY="$REPO_ROOT/.repo-venv/bin/python"
[ -x "$PY" ] || PY="python3"
"$PY" "$REPO_ROOT/bin/make-repo.py"

echo "==> Deploying to Vercel (maxleiters-team → repo.maxleiter.com)"
cd "$REPO_ROOT/repo"
vercel deploy --prod --yes --scope maxleiters-team
echo "==> Live at https://repo.maxleiter.com"
