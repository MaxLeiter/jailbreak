#!/usr/bin/env bash
# Build a prefix-aware package template for a selected Xios target.
#
#   packages/build-template-package.sh x11-fonts-sf [rootless-1900] [--stage-only]
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
X11DIR="$(cd "$HERE/.." && pwd)"
. "$X11DIR/linux-build/target-lib.sh"
_x="$HERE"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"

usage() {
  echo "usage: $0 <package> [target-id] [--stage-only]" >&2
}

[ "${1:-}" ] || { usage; exit 2; }
PKG="$1"; shift
TARGET="${XIOS_TARGET:-rootless-1900}"
STAGE_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stage-only) STAGE_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) TARGET="$1" ;;
  esac
  shift
done

xios_load_target "$TARGET"

TMPL="$HERE/templates/$PKG"
[ -d "$TMPL" ] || { echo "template not found: $TMPL" >&2; exit 2; }
[ -d "$TMPL/DEBIAN" ] || { echo "template missing DEBIAN/: $TMPL" >&2; exit 2; }

if [ -f "$TMPL/targets" ]; then
  if ! awk -v target="$XIOS_TARGET_ID" '
    /^[[:space:]]*(#|$)/ { next }
    $1 == target { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$TMPL/targets"; then
    echo "$PKG does not support target $XIOS_TARGET_ID yet (see $TMPL/targets)" >&2
    exit 2
  fi
fi

STAGEROOT="$X11DIR/linux-build/stage/$XIOS_TARGET_ID/$PKG"
STAGE="$STAGEROOT/root"
OUTDIR="$X11DIR/linux-build/out"
if [ "$XIOS_TARGET_ID" != "rootless-1900" ]; then
  OUTDIR="$OUTDIR/targets/$XIOS_TARGET_ID"
fi

render_template() {
  local src="$1" dst="$2"
  XIOS_TARGET_ID="$XIOS_TARGET_ID" \
  XIOS_MEMO_TARGET="$XIOS_MEMO_TARGET" \
  XIOS_MEMO_CFVER="$XIOS_MEMO_CFVER" \
  XIOS_PREFIX="$XIOS_PREFIX" \
  XIOS_SUBPREFIX="$XIOS_SUBPREFIX" \
  XIOS_INSTALL_PREFIX="$XIOS_INSTALL_PREFIX" \
  XIOS_DEB_ARCH="$XIOS_DEB_ARCH" \
  XIOS_REPO_PROFILE="$XIOS_REPO_PROFILE" \
  XIOS_VERSION_SUFFIX="$XIOS_VERSION_SUFFIX" \
  XIOS_PACKAGE_PATH_PREFIX="$XIOS_PACKAGE_PATH_PREFIX" \
  XIOS_RUNTIME_TMP="$XIOS_RUNTIME_TMP" \
  XIOS_RUNTIME_VAR="$XIOS_RUNTIME_VAR" \
  XIOS_DEFAULT_MIN_IOS="$XIOS_DEFAULT_MIN_IOS" \
  XIOS_PATH_DIRS="$XIOS_PATH_DIRS" \
  XIOS_SHELL_PATH="$XIOS_SHELL_PATH" \
  perl -pe '
    s/\@TARGET_ID\@/$ENV{XIOS_TARGET_ID}/g;
    s/\@MEMO_TARGET\@/$ENV{XIOS_MEMO_TARGET}/g;
    s/\@MEMO_CFVER\@/$ENV{XIOS_MEMO_CFVER}/g;
    s/\@PREFIX\@/$ENV{XIOS_PREFIX}/g;
    s/\@SUBPREFIX\@/$ENV{XIOS_SUBPREFIX}/g;
    s/\@INSTALL_PREFIX\@/$ENV{XIOS_INSTALL_PREFIX}/g;
    s/\@DEB_ARCH\@/$ENV{XIOS_DEB_ARCH}/g;
    s/\@REPO_PROFILE\@/$ENV{XIOS_REPO_PROFILE}/g;
    s/\@VERSION_SUFFIX\@/$ENV{XIOS_VERSION_SUFFIX}/g;
    s/\@PACKAGE_PATH_PREFIX\@/$ENV{XIOS_PACKAGE_PATH_PREFIX}/g;
    s/\@RUNTIME_TMP\@/$ENV{XIOS_RUNTIME_TMP}/g;
    s/\@RUNTIME_VAR\@/$ENV{XIOS_RUNTIME_VAR}/g;
    s/\@MIN_IOS\@/$ENV{XIOS_DEFAULT_MIN_IOS}/g;
    s/\@PATH_DIRS\@/$ENV{XIOS_PATH_DIRS}/g;
    s/\@SHELL_PATH\@/$ENV{XIOS_SHELL_PATH}/g;
  ' "$src" > "$dst"
}

rm -rf "$STAGEROOT"
mkdir -p "$STAGE/DEBIAN"

while IFS= read -r src; do
  rel="${src#"$TMPL/DEBIAN/"}"
  dst="$STAGE/DEBIAN/${rel%.in}"
  mkdir -p "$(dirname "$dst")"
  if [[ "$src" == *.in ]]; then
    render_template "$src" "$dst"
  else
    cp "$src" "$dst"
  fi
done < <(find "$TMPL/DEBIAN" -type f | sort)

if [ -d "$TMPL/files" ]; then
  payload_root="$STAGE$XIOS_PACKAGE_PATH_PREFIX"
  [ -n "$payload_root" ] || payload_root="$STAGE"
  mkdir -p "$payload_root"
  while IFS= read -r src; do
    rel="${src#"$TMPL/files/"}"
    dst="$payload_root/${rel%.in}"
    mkdir -p "$(dirname "$dst")"
    if [[ "$src" == *.in ]]; then
      render_template "$src" "$dst"
    else
      cp "$src" "$dst"
    fi
  done < <(find "$TMPL/files" -type f | sort)
fi

if [ -f "$TMPL/files.manifest" ]; then
  payload_root="$STAGE$XIOS_PACKAGE_PATH_PREFIX"
  [ -n "$payload_root" ] || payload_root="$STAGE"
  mkdir -p "$payload_root"
  while IFS=$'\t' read -r src rel mode; do
    case "$src" in
      ""|\#*) continue ;;
    esac
    [ -n "$rel" ] || { echo "$TMPL/files.manifest: missing destination for $src" >&2; exit 2; }
    case "$src" in
      /*) src_path="$src" ;;
      *) src_path="$TMPL/$src" ;;
    esac
    [ -f "$src_path" ] || { echo "$TMPL/files.manifest: source not found: $src" >&2; exit 2; }
    dst="$payload_root/${rel%.in}"
    mkdir -p "$(dirname "$dst")"
    if [[ "$src_path" == *.in ]]; then
      render_template "$src_path" "$dst"
    else
      cp "$src_path" "$dst"
    fi
    [ -z "${mode:-}" ] || chmod "$mode" "$dst"
  done < "$TMPL/files.manifest"
fi

find "$STAGE" -type d -exec chmod 0755 {} +
find "$STAGE/DEBIAN" -type f -exec chmod 0644 {} +
for maint in postinst preinst prerm postrm; do
  [ -f "$STAGE/DEBIAN/$maint" ] && chmod 0755 "$STAGE/DEBIAN/$maint"
done

echo "==> staged $PKG for $XIOS_TARGET_ID at $STAGE"
if [ "$STAGE_ONLY" = 1 ]; then
  find "$STAGE" -type f | sed "s#$STAGE/##" | sort
  exit 0
fi

mkdir -p "$OUTDIR"
built="$(xmkdeb "$STAGE" "$OUTDIR")"
echo "==> built $built"
