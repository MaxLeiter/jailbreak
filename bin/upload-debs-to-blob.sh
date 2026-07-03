#!/usr/bin/env bash
# Upload repo/debs/*.deb to a public Vercel Blob store using stable pathnames.
#
# Required:
#   - Vercel CLI with `vercel blob`
#   - BLOB_READ_WRITE_TOKEN in the environment, or a linked Vercel project env
#
# Optional:
#   BLOB_DEB_PREFIX=debs
#   BLOB_CACHE_CONTROL_MAX_AGE=31536000
#   BLOB_DRY_RUN=1
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEBS_DIR="${DEBS_DIR:-$REPO_ROOT/repo/debs}"
VERCEL_CWD="${VERCEL_CWD:-$REPO_ROOT/repo}"
PREFIX="${BLOB_DEB_PREFIX:-debs}"
CACHE_CONTROL_MAX_AGE="${BLOB_CACHE_CONTROL_MAX_AGE:-31536000}"

command -v vercel >/dev/null 2>&1 || {
  echo "ERROR: vercel CLI not found" >&2
  exit 1
}

[ -d "$DEBS_DIR" ] || {
  echo "ERROR: deb directory not found: $DEBS_DIR" >&2
  exit 1
}

[ -d "$VERCEL_CWD/.vercel" ] || {
  echo "ERROR: Vercel project link not found: $VERCEL_CWD/.vercel" >&2
  exit 1
}

if [ -f "$VERCEL_CWD/.env.local" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$VERCEL_CWD/.env.local"
  set +a
fi

UPLOAD_ARGS=(
  --access public
  --cache-control-max-age "$CACHE_CONTROL_MAX_AGE"
  --content-type application/x-debian-package
  --no-color
  --non-interactive
)

if [ -n "${BLOB_READ_WRITE_TOKEN:-}" ]; then
  UPLOAD_ARGS+=(--rw-token "$BLOB_READ_WRITE_TOKEN")
fi

count=0
while IFS= read -r deb; do
  name="$(basename "$deb")"
  pathname="${PREFIX%/}/$name"
  count=$((count + 1))
  if [ "${BLOB_DRY_RUN:-0}" = "1" ]; then
    echo "DRY-RUN vercel blob put $deb --pathname $pathname"
    continue
  fi
  echo "==> upload $name -> $pathname"
  (cd "$VERCEL_CWD" && vercel blob put "$deb" --pathname "$pathname" "${UPLOAD_ARGS[@]}")
done < <(find "$DEBS_DIR" -type f -name '*.deb' -print | sort)

echo "==> processed $count deb(s)"
