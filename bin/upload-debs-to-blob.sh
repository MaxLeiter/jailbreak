#!/usr/bin/env bash
# Upload repo/debs/*.deb to a public Vercel Blob store using stable pathnames.
#
# Required:
#   - Vercel CLI with `vercel blob`
#   - BLOB_READ_WRITE_TOKEN in the environment, or a linked Vercel project env
#
# Optional:
#   BLOB_DEB_PREFIX=debs
#   BLOB_PAYLOAD_ROOT=repo
#   BLOB_ONLY=package-a,package-b
#   BLOB_CACHE_CONTROL_MAX_AGE=31536000
#   BLOB_DRY_RUN=1
#   BLOB_SKIP_EXISTING=0
#   BLOB_PUBLIC_BASE_URL=https://<store>.public.blob.vercel-storage.com
#   BLOB_HEAD_TIMEOUT=20
#   BLOB_JOBS=8
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEBS_DIR="${DEBS_DIR:-$REPO_ROOT/repo/debs}"
VERCEL_CWD="${VERCEL_CWD:-$REPO_ROOT/repo}"
PAYLOAD_ROOT="${BLOB_PAYLOAD_ROOT:-$VERCEL_CWD}"
PREFIX="${BLOB_DEB_PREFIX:-debs}"
CACHE_CONTROL_MAX_AGE="${BLOB_CACHE_CONTROL_MAX_AGE:-31536000}"
PUBLIC_BASE_URL="${BLOB_PUBLIC_BASE_URL:-https://j7lqamqsi8q1vmg4.public.blob.vercel-storage.com}"
SKIP_EXISTING="${BLOB_SKIP_EXISTING:-1}"
HEAD_TIMEOUT="${BLOB_HEAD_TIMEOUT:-20}"
JOBS="${BLOB_JOBS:-8}"
ONLY="$(printf '%s' "${BLOB_ONLY:-}" | tr -d '[:space:]')"

case "$JOBS" in
  ""|*[!0-9]*) echo "ERROR: BLOB_JOBS must be a positive integer" >&2; exit 1 ;;
esac
if [ "$JOBS" -lt 1 ]; then
  echo "ERROR: BLOB_JOBS must be a positive integer" >&2
  exit 1
fi

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

# `vercel env pull` writes VERCEL_OIDC_TOKEN into .env.local but not BLOB_STORE_ID,
# and `vercel blob` rejects a HALF-SET OIDC pair outright ("must both be set, or
# both be unset") instead of falling back to the BLOB_READ_WRITE_TOKEN sitting in
# the same file. Sourcing the file therefore BREAKS uploads that would otherwise
# work. Drop an incomplete pair; a complete one is left alone so real OIDC setups
# keep working.
if [ -n "${VERCEL_OIDC_TOKEN:-}${BLOB_STORE_ID:-}" ] &&
   { [ -z "${VERCEL_OIDC_TOKEN:-}" ] || [ -z "${BLOB_STORE_ID:-}" ]; }; then
  echo "==> ignoring a half-set OIDC pair from the environment (using the read-write token)"
  unset VERCEL_OIDC_TOKEN BLOB_STORE_ID
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

process_deb() {
  local deb="$1"
  local name pathname url headers status remote_size local_size upload_log rc
  local upload_args=(
    --access public
    --cache-control-max-age "$CACHE_CONTROL_MAX_AGE"
    --content-type application/x-debian-package
    --no-color
    --non-interactive
  )

  if [ -n "${BLOB_READ_WRITE_TOKEN:-}" ]; then
    upload_args+=(--rw-token "$BLOB_READ_WRITE_TOKEN")
  fi

  name="$(basename "$deb")"
  pathname="${PREFIX%/}/$name"
  url="${PUBLIC_BASE_URL%/}/$pathname"

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
      printf 'skipped\n' >> "$RESULTS"
      echo "==> skip existing $pathname"
      return 0
    fi
    if [ -n "$status" ] && [ "$status" != "404" ]; then
      echo "ERROR: unexpected Blob status for $pathname: HTTP $status" >&2
      exit 1
    fi
  fi

  if [ "${BLOB_DRY_RUN:-0}" = "1" ]; then
    printf 'would_upload\n' >> "$RESULTS"
    echo "DRY-RUN vercel blob put $deb --pathname $pathname"
    return 0
  fi

  echo "==> upload $name -> $pathname"
  upload_log="$(mktemp)"
  if (cd "$VERCEL_CWD" && vercel blob put "$deb" --pathname "$pathname" "${upload_args[@]}") >"$upload_log" 2>&1; then
    cat "$upload_log"
    rm -f "$upload_log"
    printf 'uploaded\n' >> "$RESULTS"
  else
    rc=$?
    cat "$upload_log"
    if grep -q "This blob already exists" "$upload_log"; then
      rm -f "$upload_log"
      printf 'skipped\n' >> "$RESULTS"
      echo "==> skip existing $pathname (blob put reported existing)"
      return 0
    fi
    rm -f "$upload_log"
    exit "$rc"
  fi
}

RESULTS="$(mktemp)"
LIST="$(mktemp)"
trap 'rm -f "$RESULTS" "$LIST"' EXIT

if [ -n "$ONLY" ]; then
  INDEX="${BLOB_INDEX:-$VERCEL_CWD/Packages}"
  [ -f "$INDEX" ] || {
    echo "ERROR: scoped Blob upload needs the generated index at $INDEX" >&2
    exit 1
  }
  awk -v only=",$ONLY," '
    /^Package: /  { package = $2 }
    /^Filename: / {
      if (index(only, "," package ",") != 0)
        print $2
    }
  ' "$INDEX" | while IFS= read -r filename; do
    deb="$PAYLOAD_ROOT/$filename"
    [ -f "$deb" ] || {
      echo "ERROR: indexed payload missing for scoped upload: $filename" >&2
      exit 1
    }
    printf '%s\n' "$deb"
  done > "$LIST"
  expected="$(awk -F, '{ print NF }' <<EOF
$ONLY
EOF
)"
  selected="$(wc -l < "$LIST" | tr -d '[:space:]')"
  [ "$selected" = "$expected" ] || {
    echo "ERROR: scoped Blob upload selected $selected payload(s), expected $expected: $ONLY" >&2
    exit 1
  }
  echo "==> scoped Blob upload: $ONLY"
else
  find "$DEBS_DIR" -type f -name '*.deb' -print | sort > "$LIST"
fi
count="$(wc -l < "$LIST" | tr -d '[:space:]')"

export VERCEL_CWD PREFIX CACHE_CONTROL_MAX_AGE PUBLIC_BASE_URL SKIP_EXISTING
export HEAD_TIMEOUT RESULTS BLOB_DRY_RUN
export -f blob_status process_deb

echo "==> processing $count deb(s) with $JOBS upload job(s)"
if [ "$count" -gt 0 ]; then
  if ! xargs -n 1 -P "$JOBS" bash -c 'process_deb "$1"' _ < "$LIST"; then
    echo "ERROR: one or more Blob upload jobs failed" >&2
    exit 1
  fi
fi

uploaded="$(grep -c '^uploaded$' "$RESULTS" 2>/dev/null || true)"
would_upload="$(grep -c '^would_upload$' "$RESULTS" 2>/dev/null || true)"
skipped="$(grep -c '^skipped$' "$RESULTS" 2>/dev/null || true)"

if [ "${BLOB_DRY_RUN:-0}" = "1" ]; then
  echo "==> processed $count deb(s): would_upload=$would_upload skipped=$skipped"
else
  echo "==> processed $count deb(s): uploaded=$uploaded skipped=$skipped"
fi
