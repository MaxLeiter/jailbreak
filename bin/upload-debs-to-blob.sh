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
#   BLOB_SKIP_EXISTING=0
#   BLOB_PUBLIC_BASE_URL=https://<store>.public.blob.vercel-storage.com
#   BLOB_HEAD_TIMEOUT=20
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEBS_DIR="${DEBS_DIR:-$REPO_ROOT/repo/debs}"
VERCEL_CWD="${VERCEL_CWD:-$REPO_ROOT/repo}"
PREFIX="${BLOB_DEB_PREFIX:-debs}"
CACHE_CONTROL_MAX_AGE="${BLOB_CACHE_CONTROL_MAX_AGE:-31536000}"
PUBLIC_BASE_URL="${BLOB_PUBLIC_BASE_URL:-https://j7lqamqsi8q1vmg4.public.blob.vercel-storage.com}"
SKIP_EXISTING="${BLOB_SKIP_EXISTING:-1}"
HEAD_TIMEOUT="${BLOB_HEAD_TIMEOUT:-20}"

command -v vercel >/dev/null 2>&1 || {
  echo "ERROR: vercel CLI not found" >&2
  exit 1
}

if [ "$SKIP_EXISTING" = "1" ]; then
  command -v curl >/dev/null 2>&1 || {
    echo "ERROR: curl not found; set BLOB_SKIP_EXISTING=0 to upload without preflight checks" >&2
    exit 1
  }
fi

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

blob_status() {
  local url="$1"
  curl -sSI --connect-timeout 5 --max-time "$HEAD_TIMEOUT" "$url" | tr -d '\r'
}

count=0
uploaded=0
would_upload=0
skipped=0
while IFS= read -r deb; do
  name="$(basename "$deb")"
  pathname="${PREFIX%/}/$name"
  url="${PUBLIC_BASE_URL%/}/$pathname"
  count=$((count + 1))

  if [ "$SKIP_EXISTING" = "1" ]; then
    headers="$(blob_status "$url" || true)"
    status="$(printf '%s\n' "$headers" | awk '/^HTTP\// { code=$2 } END { print code }')"
    if [ "$status" = "200" ]; then
      remote_size="$(printf '%s\n' "$headers" | awk 'tolower($1) == "content-length:" { print $2; exit }')"
      local_size="$(wc -c < "$deb" | tr -d '[:space:]')"
      if [ "$remote_size" != "$local_size" ]; then
        echo "ERROR: existing Blob has different size for $pathname (remote=$remote_size local=$local_size)" >&2
        echo "       Public package filenames are immutable; build a new package version instead of overwriting." >&2
        exit 1
      fi
      skipped=$((skipped + 1))
      echo "==> skip existing $pathname"
      continue
    fi
    if [ -n "$status" ] && [ "$status" != "404" ]; then
      echo "ERROR: unexpected Blob status for $pathname: HTTP $status" >&2
      exit 1
    fi
  fi

  if [ "${BLOB_DRY_RUN:-0}" = "1" ]; then
    would_upload=$((would_upload + 1))
    echo "DRY-RUN vercel blob put $deb --pathname $pathname"
    continue
  fi
  echo "==> upload $name -> $pathname"
  (cd "$VERCEL_CWD" && vercel blob put "$deb" --pathname "$pathname" "${UPLOAD_ARGS[@]}")
  uploaded=$((uploaded + 1))
done < <(find "$DEBS_DIR" -type f -name '*.deb' -print | sort)

if [ "${BLOB_DRY_RUN:-0}" = "1" ]; then
  echo "==> processed $count deb(s): would_upload=$would_upload skipped=$skipped"
else
  echo "==> processed $count deb(s): uploaded=$uploaded skipped=$skipped"
fi
