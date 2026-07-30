#!/usr/bin/env bash
# Regenerate the APT repo index and deploy it to Vercel.
#
# ---------------------------------------------------------------------------
# THE WHOLE PROCEDURE, in order. Follow it top to bottom; each step is safe to
# rerun. Do not improvise a different order -- the ordering is what keeps the
# published index and the payloads it points at in agreement.
#
#   1. bin/build.sh tweaks/<Name>              # or the x11/ build for that package
#   2. cp tweaks/<Name>/packages/*.deb repo/debs/
#   3. bin/publish-staging.sh                  # payloads -> Blob, deploy dev.repo,
#                                              # and regenerate repo/Packages
#   4. test it on the device from dev.repo.maxleiter.com
#   5. git add repo/Packages && git commit     # REVIEW THE DIFF: it is exactly
#                                              # what step 6 will make public
#   6. bin/publish-repo.sh                     # production
#
# Step 5 is not bookkeeping. Step 6 publishes the COMMITTED index, so the diff
# you commit is the change users receive; anything you leave uncommitted stays
# unpublished. Skipping step 3 means the payloads were never uploaded and step 6
# publishes an index pointing at 404s -- so never run step 6 alone for a package
# built on this machine.
#
# Targets:
#   bin/publish-repo.sh              # production (repo.maxleiter.com)
#   bin/publish-repo.sh --staging    # low-cache staging repo (dev.repo.maxleiter.com)
#   bin/publish-staging.sh           # same as --staging
#   bin/publish-repo.sh --preview    # throwaway Vercel preview URL (per-branch testing)
# ---------------------------------------------------------------------------
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
#
# WHERE THE INDEX COMES FROM -- the defaults are chosen so the safe thing happens
# when nobody passes a flag, because "publish the repo" is the instruction people
# and agents actually give.
#
#   staging/preview  default --from-debs:  rebuild Packages from repo/debs. That
#     is what staging is FOR -- you just built something and want to see it.
#
#   prod             default --from-index: publish the COMMITTED repo/Packages and
#     only rebuild the metadata derived from it. repo/debs accumulates every
#     package anyone on this box has built, so rebuilding from it at prod ships
#     the whole pending delta rather than your change (2026-07-28: that delta was
#     33 packages). Publishing the committed index instead makes what ships equal
#     to what is in the diff. To enforce that rather than just intend it, a prod
#     --from-index publish REFUSES to run when repo/Packages differs from HEAD.
#
# --from-index skips the payload-level gates (DER signing, Blob upload, and the
# Procursus shadow check, which needs Mach-O nm over the real debs), so the debs
# must ALREADY be in Blob -- run `bin/publish-staging.sh` from the tree that built
# them first. It also needs no payloads on disk, which makes it the only way to
# publish from a worktree. --from-index is the whole-index counterpart to --only:
# --only reconciles against what the target serves, --from-index publishes what
# git says.
set -euo pipefail

TARGET=prod
ONLY=""
SOURCE=""   # empty until the per-target default is applied below
while [ "$#" -gt 0 ]; do
  case "$1" in
    --staging|staging) TARGET=staging ;;
    --prod|prod)       TARGET=prod ;;
    --preview|preview) TARGET=preview ;;
    --only)            ONLY="${2:-}"; shift ;;
    --only=*)          ONLY="${1#--only=}" ;;
    --from-index)      SOURCE=index ;;
    --from-debs)       SOURCE=debs ;;
    "") ;;
    *) echo "usage: bin/publish-repo.sh [--staging|--prod|--preview] [--only pkg[,pkg...]] [--from-index|--from-debs]" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "$SOURCE" ]; then
  case "$TARGET" in
    prod) SOURCE=index ;;
    *)    SOURCE=debs ;;
  esac
fi
echo "==> target=$TARGET index-source=$SOURCE${ONLY:+ only=$ONLY}"

# This script publishes the flat rootless repo. Other profiles can be generated
# locally (XIOS_REPO_PROFILE=rootful bin/lib/make-repo.py writes an independent
# tree under repo/profiles/), but publishing one needs its own domain, project
# and Blob prefix, and per the migration plan must not happen before a real
# rootful device has passed install and launch smoke tests.
if [ "${XIOS_REPO_PROFILE:-rootless}" != "rootless" ]; then
  echo "ERROR: publishing the '$XIOS_REPO_PROFILE' profile is not wired up." >&2
  echo "       Generate it locally for inspection instead:" >&2
  echo "         XIOS_REPO_PROFILE=$XIOS_REPO_PROFILE .repo-venv/bin/python bin/lib/make-repo.py" >&2
  echo "       See x11/docs/rootless-rootful-cfver-migration-plan.md, Phase 5." >&2
  exit 2
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCKDIR="${TMPDIR:-/tmp}/maxleiter-repo-publish.lock"
SCOPE="${VERCEL_SCOPE:-maxleiters-team}"
PROD_DOMAIN="${PROD_REPO_DOMAIN:-repo.maxleiter.com}"
PROD_PROJECT="${PROD_REPO_PROJECT:-repo}"
# Staging keeps the historical dev.repo.maxleiter.com domain and repo-dev project.
STAGING_DOMAIN="${STAGING_REPO_DOMAIN:-dev.repo.maxleiter.com}"
STAGING_PROJECT="${STAGING_REPO_PROJECT:-repo-dev}"

# Use the Pillow venv if present (for icon/banner generation), else system python.
PY="$REPO_ROOT/.repo-venv/bin/python"
[ -x "$PY" ] || PY="python3"

REPO_KEY="repo@maxleiter.com"

# "Publish exactly what is committed" is only true if the file on disk IS what is
# committed. repo/Packages is regenerated by every staging publish, so by the time
# you reach prod the working copy usually holds the full repo/debs index again --
# publishing that under --from-index would quietly ship the accumulated delta the
# flag exists to avoid. Enforce it instead of documenting it.
if [ "$TARGET" = prod ] && [ "$SOURCE" = index ]; then
  repo_root_for_git="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if ! git -C "$repo_root_for_git" diff --quiet HEAD -- repo/Packages 2>/dev/null; then
    echo "ERROR: repo/Packages differs from HEAD, so --from-index would not publish what is committed." >&2
    echo "       This is the normal state right after a staging publish (it regenerates the" >&2
    echo "       index from every deb in repo/debs). Pick one:" >&2
    echo "         git add repo/Packages && git commit    # ship it: review the diff first" >&2
    echo "         git checkout HEAD -- repo/Packages     # ship what is already committed" >&2
    echo "         bin/publish-repo.sh --from-debs        # deliberately ship the whole tree" >&2
    exit 1
  fi
fi

# A preview URL nobody's apt is pinned to may go out unsigned; the real repos may
# not. An unsigned index is not a missing nicety, it makes apt reject the whole
# repo, so check for the key BEFORE spending minutes regenerating and uploading.
if [ "$TARGET" != preview ] && [ "${ALLOW_UNSIGNED:-0}" != 1 ] \
   && ! gpg --list-secret-keys "$REPO_KEY" >/dev/null 2>&1; then
  echo "ERROR: no signing key ($REPO_KEY) in the keyring; refusing to publish $TARGET unsigned." >&2
  echo "       Device apt rejects an unsigned repo, so this would break apt for every" >&2
  echo "       installed device, not just skip a signature. Set ALLOW_UNSIGNED=1 to override." >&2
  exit 1
fi

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

  # Two limits, because this pass used to walk every .deb in the tree on every
  # publish: ~770 packages / ~750MB unpacked, repacked and re-signed serially, to
  # produce zero changes in the normal case. It dominated publish time and, with
  # several sessions publishing at once behind one lock, it was most of the queue.
  #
  #   --only    a scoped publish deploys nothing but the named packages, so signing
  #             the rest cannot affect what ships.
  #   --cache   re-signing is deterministic and byte-stable (see the signer's own
  #             docstring), so a .deb whose size+mtime is unchanged since it last
  #             passed cannot need work. Correctness still comes from the signer:
  #             the cache only decides what to look at, never what is valid.
  local cache="${XDG_CACHE_HOME:-$HOME/.cache}/xios-der-resign.stamps"
  mkdir -p "$(dirname "$cache")"
  local scope=()
  [ -n "${ONLY:-}" ] && scope=(--only "$ONLY")

  echo "==> DER-signing X11 graphics packages in repo/debs${ONLY:+ (scoped: $ONLY)}"
  python3 "$signer" "$REPO_ROOT/repo/debs" \
    --ldid "$ldid_bin" \
    --gpu-ent "$gpu_ent" \
    --gl-ent "$gl_ent" \
    --cache "$cache" \
    "${scope[@]}"
}

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
  local project="$1" config_name="$2" domain="$3" mode="${4:-prod}"
  local deploy_root
  deploy_root="$(mktemp -d "${TMPDIR:-/tmp}/maxleiter-repo-deploy.XXXXXX")"
  cleanup_deploy_root() { rm -rf "$deploy_root"; }
  trap cleanup_deploy_root RETURN

  mkdir -p "$deploy_root/repo"
  # The Vercel CLI applies a .gitignore found in the directory it uploads, so
  # repo/.gitignore doubles as an upload filter -- see the comment in that file.
  # It is copied deliberately: it is what keeps .env.local (BLOB_READ_WRITE_TOKEN)
  # out of the public repo. The excludes below do not depend on it.
  rsync -a --delete \
    --exclude 'debs/' \
    --exclude '.vercel/' \
    --exclude '.env' --exclude '.env.*' \
    "$REPO_ROOT/repo/" "$deploy_root/repo/"

  # Never ship a credential. Belt to the .gitignore/.vercelignore braces, because
  # this one is unrecoverable: a token served once from a public URL is burned.
  local leaked
  leaked="$(find "$deploy_root/repo" \( -name '.env' -o -name '.env.*' -o -name '*.pem' \
            -o -name 'id_rsa*' -o -name '.netrc' \) -print 2>/dev/null | head -5)"
  if [ -n "$leaked" ]; then
    echo "ERROR: refusing to deploy, the staged copy contains credential files:" >&2
    printf '       %s\n' $leaked >&2
    exit 1
  fi

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

    # make-repo.py prunes depictions/icons/banners for packages that left the
    # tree's index. A scoped deploy serves the LIVE index, which can still name a
    # package this branch retired -- so the scoped index is the one place where a
    # stanza can outlive its assets. Cosmetic (a 404 depiction, apt is unaffected)
    # so it warns rather than blocks, but silently shipping a broken Sileo page is
    # worth a line of output.
    local dangling
    dangling="$(comm -23 \
      <(awk '/^Package: /{print $2}' "$deploy_root/repo/Packages" | sort -u) \
      <(ls "$deploy_root/repo/depictions" 2>/dev/null | sed -n 's/\.html$//p' | sort -u))"
    if [ -n "$dangling" ]; then
      echo "   WARNING: the scoped index names $(echo "$dangling" | wc -l | tr -d ' ') package(s) with no depiction in this upload:" >&2
      echo "$dangling" | sed 's/^/     /' >&2
      echo "     (retired on this branch but still live on $domain; a full publish clears it)" >&2
    fi
  fi

  # Everything apt reads must exist in the upload. Checked here, on the staged
  # copy, because a deploy that drops these still "succeeds" -- Packages keeps
  # serving and only apt notices, on every device at once.
  local missing=""
  for f in Packages Packages.gz Release InRelease Release.gpg; do
    [ -s "$deploy_root/repo/$f" ] || missing="$missing $f"
  done
  if [ -n "$missing" ]; then
    echo "ERROR: the deploy copy is missing apt metadata:$missing" >&2
    echo "       Refusing to deploy an index apt cannot verify. Check the rsync" >&2
    echo "       filters in deploy_static_repo and repo/.gitignore." >&2
    exit 1
  fi

  local args=(deploy "$deploy_root" --yes --scope "$SCOPE" --project "$project"
              --local-config "$deploy_root/repo/$config_name" --no-color)
  [ "$mode" = prod ] && args+=(--prod)
  [ -n "${VERCEL_TOKEN:-}" ] && args+=(--token "$VERCEL_TOKEN")

  local base
  if [ "$mode" = prod ]; then
    vercel "${args[@]}"
    base="https://$domain"
    echo "==> Live at $base"
  else
    # Preview: the deployment URL is the whole point, so capture it. Vercel prints
    # progress to stderr and the URL to stdout.
    base="$(vercel "${args[@]}")"
    echo "==> Preview at $base"
  fi

  verify_published "$base" "$mode"
}

# Fetch back what we just deployed. The staged-copy check above cannot see an
# upload-time filter (the Vercel CLI honors a .gitignore in the uploaded
# directory), which is exactly how prod once ended up serving Packages while
# 404ing Release. Only the live URL proves it.
verify_published() {
  local base="$1" mode="${2:-prod}"
  command -v curl >/dev/null 2>&1 || return 0
  # Preview deployments sit behind Vercel SSO, so their URLs are not fetchable.
  [ "$mode" = prod ] || { echo "   (preview URLs are SSO-protected; skipping fetch-back)"; return 0; }

  echo "==> Verifying $base serves what apt needs"
  local bad="" code
  for f in Packages Packages.gz Release InRelease Release.gpg; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$base/$f" || echo 000)"
    printf '    %-14s HTTP %s\n' "$f" "$code"
    [ "$code" = 200 ] || bad="$bad $f"
  done
  if [ -n "$bad" ]; then
    echo "ERROR: deployed, but these are not being served:$bad" >&2
    echo "       apt will report 'does not have a Release file' until this is fixed." >&2
    exit 1
  fi
  echo "   all present"
}

# Which already-published index does this deploy have to stay consistent with?
# Publishing an index that reuses a version with different bytes cannot work
# (Blob filenames are immutable) and publishing one that is behind would roll
# devices back, so check both before touching anything.
case "$TARGET" in
  prod)    DRIFT_REF="https://$PROD_DOMAIN/Packages" ;;
  staging) DRIFT_REF="https://$STAGING_DOMAIN/Packages" ;;
  preview) DRIFT_REF="" ;;
esac

if [ "$SOURCE" = index ]; then
  echo "==> Metadata-only publish: committed repo/Packages is authoritative"
  echo "    (payload gates skipped: DER signing, Blob upload, Procursus shadow check)"
  "$PY" "$REPO_ROOT/bin/lib/make-repo.py" --from-index
  "$PY" "$REPO_ROOT/bin/lib/check-repo-solvable.py" "$REPO_ROOT/repo/Packages"
  "$PY" "$REPO_ROOT/bin/lib/audit-repo.py" --repo "$REPO_ROOT/repo" --no-payloads
  BEFORE=""
else
  finalize_x11_graphics_debs
  BEFORE="$(snapshot_debs)"

  echo "==> Regenerating index (Packages / Release / depictions / assets)"
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
fi

if [ -n "$DRIFT_REF" ]; then
  echo "==> Checking the index against what $TARGET already publishes"
  # With --only, being behind the target is the normal case -- scope-index.py
  # reconciles against the live index on the deploy copy -- so regressions are
  # informational there. Collisions stay fatal for the packages actually being
  # shipped, since those bytes cannot be uploaded at all; for everything else a
  # scoped publish neither uploads nor reindexes them, so they are out of scope.
  if [ -n "$ONLY" ]; then
    # Also scope WHICH packages are checked, not just how regressions are treated.
    # A scoped publish uploads nothing but these packages and reuses every other
    # stanza from the target verbatim, so another package colliding cannot affect
    # what ships here -- and used to fail the run anyway, which meant one session's
    # un-bumped package blocked every other session's unrelated hotfix.
    "$PY" "$REPO_ROOT/bin/lib/check-version-collisions.py" \
      --against "$DRIFT_REF" --only "$ONLY" --warn-regressions
  else
    "$PY" "$REPO_ROOT/bin/lib/check-version-collisions.py" --against "$DRIFT_REF"
  fi
fi

echo "==> Signing the index (InRelease + Release.gpg)"
sign_index "$REPO_ROOT/repo"

if [ "$SOURCE" = debs ]; then
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
fi

cd "$REPO_ROOT/repo"
case "$TARGET" in
  staging)
    echo "==> Deploying staging repo to Vercel ($SCOPE/$STAGING_PROJECT -> $STAGING_DOMAIN)"
    deploy_static_repo "$STAGING_PROJECT" "vercel.staging.json" "$STAGING_DOMAIN" prod
    ;;
  preview)
    # Preview deploys ride the staging project (same low-cache headers) but do not
    # take its domain, so a branch can be installed on a device from its own URL
    # without touching dev.repo or prod.
    echo "==> Deploying preview to Vercel ($SCOPE/$STAGING_PROJECT, no domain alias)"
    deploy_static_repo "$STAGING_PROJECT" "vercel.staging.json" "$STAGING_DOMAIN" preview
    ;;
  prod)
    echo "==> Deploying to Vercel ($SCOPE/$PROD_PROJECT -> $PROD_DOMAIN)"
    deploy_static_repo "$PROD_PROJECT" "vercel.prod.json" "$PROD_DOMAIN" prod
    ;;
esac
