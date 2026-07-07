#!/usr/bin/env bash
# Regenerate the APT repo index and deploy it to Vercel.
#
#   bin/publish-repo.sh              # production (repo.maxleiter.com)
#   bin/publish-repo.sh --staging    # low-cache staging repo (dev.repo.maxleiter.com)
#   bin/publish-staging.sh           # same as --staging
#
# To publish a tweak: build it, copy its .deb into repo/debs/, then run this.
#   bin/build.sh tweaks/<Name>
#   cp tweaks/<Name>/packages/*.deb repo/debs/
#   bin/publish-repo.sh          # uploads payloads to Blob, signs metadata, deploys metadata
set -euo pipefail

TARGET=prod
case "${1:-}" in
  --staging|staging) TARGET=staging ;;
  "") ;;
  *) echo "usage: bin/publish-repo.sh [--staging]" >&2; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCKDIR="${TMPDIR:-/tmp}/maxleiter-repo-publish.lock"
SCOPE="${VERCEL_SCOPE:-maxleiters-team}"
PROD_DOMAIN="${PROD_REPO_DOMAIN:-repo.maxleiter.com}"
PROD_PROJECT="${PROD_REPO_PROJECT:-repo}"
# Staging keeps the historical dev.repo.maxleiter.com domain and repo-dev project.
STAGING_DOMAIN="${STAGING_REPO_DOMAIN:-dev.repo.maxleiter.com}"
STAGING_PROJECT="${STAGING_REPO_PROJECT:-repo-dev}"

if ! mkdir "$LOCKDIR" 2>/dev/null; then
  echo "ERROR: another repo publish is already running ($LOCKDIR)" >&2
  exit 1
fi
trap 'rm -rf "$LOCKDIR"' EXIT

snapshot_debs() {
  find "$REPO_ROOT/repo/debs" -type f -name '*.deb' -print0 \
    | sort -z \
    | xargs -0 shasum -a 256
}

finalize_x11_graphics_debs() {
  local signer="$REPO_ROOT/x11/linux-build/resign-graphics-packages.py"
  local gpu_ent="$REPO_ROOT/x11/linux-build/build_info/iosc-gpu-client-ent.xml"
  local gl_ent="$REPO_ROOT/x11/linux-build/build_info/iosc-gl-ent.xml"
  local ldid_bin="${LDID:-/opt/homebrew/bin/ldid}"

  [ -x "$signer" ] || return 0
  [ -f "$gpu_ent" ] && [ -f "$gl_ent" ] || return 0
  if [ ! -x "$ldid_bin" ]; then
    ldid_bin="$(command -v ldid || true)"
  fi
  if [ -z "$ldid_bin" ] || [ ! -x "$ldid_bin" ]; then
    echo "ERROR: ldid not found; cannot DER-sign X11 graphics packages before publishing." >&2
    exit 1
  fi

  echo "==> DER-signing X11 graphics packages in repo/debs"
  python3 "$signer" "$REPO_ROOT/repo/debs" \
    --ldid "$ldid_bin" \
    --gpu-ent "$gpu_ent" \
    --gl-ent "$gl_ent"
}

deploy_static_repo() {
  local project="$1" config_name="$2" domain="$3"
  local deploy_root
  deploy_root="$(mktemp -d "${TMPDIR:-/tmp}/maxleiter-repo-deploy.XXXXXX")"
  cleanup_deploy_root() { rm -rf "$deploy_root"; }
  trap cleanup_deploy_root RETURN

  mkdir -p "$deploy_root/repo"
  rsync -a --delete --exclude 'debs/' --exclude '.vercel/' \
    "$REPO_ROOT/repo/" "$deploy_root/repo/"

  vercel deploy "$deploy_root" --prod --yes --scope "$SCOPE" --project "$project" \
    --local-config "$deploy_root/repo/$config_name" --no-color
  echo "==> Live at https://$domain"
}

finalize_x11_graphics_debs
BEFORE="$(snapshot_debs)"

echo "==> Regenerating index (Packages / Release / depictions / assets)"
# Use the Pillow venv if present (for icon/banner generation), else system python.
PY="$REPO_ROOT/.repo-venv/bin/python"
[ -x "$PY" ] || PY="python3"
"$PY" "$REPO_ROOT/bin/lib/make-repo.py"
"$PY" "$REPO_ROOT/bin/lib/check-repo-solvable.py" "$REPO_ROOT/repo/Packages"
"$PY" "$REPO_ROOT/bin/lib/audit-repo.py" --repo "$REPO_ROOT/repo"

AFTER_INDEX="$(snapshot_debs)"
if [ "$BEFORE" != "$AFTER_INDEX" ]; then
  echo "ERROR: repo/debs changed while Packages was being generated; rerun publish after the active build finishes." >&2
  exit 1
fi

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

AFTER_SIGN="$(snapshot_debs)"
if [ "$BEFORE" != "$AFTER_SIGN" ]; then
  echo "ERROR: repo/debs changed after signing; refusing to deploy a stale index." >&2
  exit 1
fi

echo "==> Uploading package payloads to Vercel Blob"
"$REPO_ROOT/bin/upload-debs-to-blob.sh"

AFTER_UPLOAD="$(snapshot_debs)"
if [ "$BEFORE" != "$AFTER_UPLOAD" ]; then
  echo "ERROR: repo/debs changed during Blob upload; refusing to deploy a stale index." >&2
  exit 1
fi

cd "$REPO_ROOT/repo"
if [ "$TARGET" = staging ]; then
  echo "==> Deploying staging repo to Vercel ($SCOPE/$STAGING_PROJECT -> $STAGING_DOMAIN)"
  deploy_static_repo "$STAGING_PROJECT" "vercel.staging.json" "$STAGING_DOMAIN"
else
  echo "==> Deploying to Vercel ($SCOPE/$PROD_PROJECT -> $PROD_DOMAIN)"
  deploy_static_repo "$PROD_PROJECT" "vercel.prod.json" "$PROD_DOMAIN"
fi
