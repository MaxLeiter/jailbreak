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
#
# ONE PACKAGE AT A TIME:
#   bin/publish-repo.sh --only iosc,xios-session
#
# The tree is the STAGING state -- repo/debs accumulates everything anyone has
# built -- so a bare publish to prod ships every pending delta, not just yours.
# --only takes the index the target is ALREADY serving and swaps in just the named
# packages, leaving every other stanza exactly as published. It rewrites the index
# in the throwaway deploy copy, never in repo/, so nothing has to be moved out of
# repo/debs and back (the old workaround, which raced concurrent publishes) and an
# interrupted run cannot leave the tree misindexed. Dependency solvability is
# re-checked against the SCOPED index, which is what catches shipping half of a
# package pair.
#
# To preview without deploying, run the scoper alone against a copy:
#   cp -r repo /tmp/preview && bin/lib/scope-index.py --repo /tmp/preview \
#     --live https://repo.maxleiter.com/Packages --only iosc
# It prints the exact version transitions and refuses a no-op (which is how you
# find out the deb in repo/debs is stale).
#
# SCOPE OF --only, precisely: Packages, Packages.gz, Release, InRelease and
# Release.gpg -- everything apt reads, so what users can install is exactly the
# live set plus your packages. It does NOT scope the static site that deploys
# alongside it (index.html, depictions/, banners/, icons/, sileo-featured.json):
# those are regenerated from every deb in repo/debs, so a depiction page for a
# package that is not in the scoped index can still be reachable by URL. Cosmetic,
# not installable, but it means a scoped prod publish still carries whatever site
# assets the tree currently has.
set -euo pipefail

TARGET=prod
ONLY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --staging|staging) TARGET=staging ;;
    --only) ONLY="${2:-}"; shift ;;
    --only=*) ONLY="${1#--only=}" ;;
    "") ;;
    *) echo "usage: bin/publish-repo.sh [--staging] [--only pkg[,pkg...]]" >&2; exit 2 ;;
  esac
  shift
done
[ -z "$ONLY" ] || echo "==> scoped publish: only $ONLY"

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

REPO_KEY="repo@maxleiter.com"

# Sign whichever copy of the index we are about to serve. Called for the tree, and
# again for the deploy copy when --only rewrote it (the hashes changed, so the
# tree's signature would not verify against the scoped Release).
sign_index() {
  local dir="$1"
  if gpg --list-secret-keys "$REPO_KEY" >/dev/null 2>&1; then
    gpg --batch --yes --pinentry-mode loopback --default-key "$REPO_KEY" \
        --clearsign -o "$dir/InRelease" "$dir/Release"
    gpg --batch --yes --pinentry-mode loopback --default-key "$REPO_KEY" \
        -abs -o "$dir/Release.gpg" "$dir/Release"
    gpg --export "$REPO_KEY" > "$dir/maxleiter-repo.gpg"
    echo "   signed with $REPO_KEY (public key at maxleiter-repo.gpg)"
  else
    echo "   WARNING: no signing key ($REPO_KEY) — publishing UNSIGNED (device apt will reject the repo)"
  fi
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

  # --only: serve the target's current index with just the named packages swapped
  # in. Done here, on the throwaway copy, so repo/ keeps its full (staging) index.
  if [ -n "$ONLY" ]; then
    echo "==> Scoping the index to: $ONLY (against https://$domain/Packages)"
    "$PY" "$REPO_ROOT/bin/lib/scope-index.py" \
      --repo "$deploy_root/repo" \
      --live "https://$domain/Packages" \
      --only "$ONLY"
    # Re-check solvability on what we are ACTUALLY publishing. The full-tree check
    # earlier passed because the tree has everything; prod may not. This is the
    # gate that catches publishing one half of a package pair.
    "$PY" "$REPO_ROOT/bin/lib/check-repo-solvable.py" "$deploy_root/repo/Packages"
    echo "==> Re-signing the scoped index"
    sign_index "$deploy_root/repo"
  fi

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
# Drop-in-superset gate for debs shadowing Procursus package names (soname/file
# parity + upstream-version pinning + -dev runtime-dylib lint). Waivers with
# reasons in bin/lib/shadow-waivers.json. Born from the 2026-07-08 device brick.
"$PY" "$REPO_ROOT/bin/lib/check-procursus-shadow.py"

AFTER_INDEX="$(snapshot_debs)"
if [ "$BEFORE" != "$AFTER_INDEX" ]; then
  echo "ERROR: repo/debs changed while Packages was being generated; rerun publish after the active build finishes." >&2
  exit 1
fi

echo "==> Signing the index (InRelease + Release.gpg)"
sign_index "$REPO_ROOT/repo"

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
