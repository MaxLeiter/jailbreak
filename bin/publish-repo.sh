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

echo "==> Signing the index (InRelease + Release.gpg)"
REPO_KEY="repo@maxleiter.com"
if gpg --list-secret-keys "$REPO_KEY" >/dev/null 2>&1; then
  gpg --batch --yes --pinentry-mode loopback --default-key "$REPO_KEY" \
      --clearsign -o "$REPO_ROOT/repo/InRelease" "$REPO_ROOT/repo/Release"
  gpg --batch --yes --pinentry-mode loopback --default-key "$REPO_KEY" \
      -abs -o "$REPO_ROOT/repo/Release.gpg" "$REPO_ROOT/repo/Release"
  gpg --export "$REPO_KEY" > "$REPO_ROOT/repo/maxleiter-repo.gpg"
  echo "   signed with $REPO_KEY (public key at repo/maxleiter-repo.gpg)"
else
  echo "   WARNING: no signing key ($REPO_KEY) — publishing UNSIGNED (device apt will reject the repo)"
fi

echo "==> Deploying to Vercel (maxleiters-team → repo.maxleiter.com)"
cd "$REPO_ROOT/repo"
vercel deploy --prod --yes --scope maxleiters-team
echo "==> Live at https://repo.maxleiter.com"
