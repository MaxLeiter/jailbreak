#!/usr/bin/env bash
# Assemble xios-server for a selected Xios target from a target-built Xios binary.
set -euo pipefail

PKGDIR="$(cd "$(dirname "$0")" && pwd)"
X11DIR="$(cd "$PKGDIR/../.." && pwd)"
. "$X11DIR/linux-build/target-lib.sh"
_x="$PKGDIR"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"

TARGET="${XIOS_TARGET:-rootless-1900}"
STAGE_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stage-only) STAGE_ONLY=1 ;;
    -h|--help)
      echo "usage: $0 [target-id] [--stage-only]" >&2
      exit 0
      ;;
    *) TARGET="$1" ;;
  esac
  shift
done

xios_load_target "$TARGET"

TMPL="$X11DIR/packages/templates/xios-server"
OUT="$X11DIR/linux-build/out"
PKGOUT="$OUT"
if [ "$XIOS_TARGET_ID" != "rootless-1900" ]; then
  PKGOUT="$OUT/targets/$XIOS_TARGET_ID"
fi

XIOS_SRC="$OUT/targets/$XIOS_TARGET_ID/Xios"
if [ "$XIOS_TARGET_ID" = "rootless-1900" ] && [ ! -f "$XIOS_SRC" ]; then
  XIOS_SRC="$PKGDIR/var/jb/usr/bin/Xios"
fi
[ -f "$XIOS_SRC" ] || {
  echo "missing target-built Xios for $XIOS_TARGET_ID: $XIOS_SRC" >&2
  echo "build it with: bash linux-build/build-xserver-target.sh $XIOS_TARGET_ID" >&2
  exit 1
}

render_template() {
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
  ' "$1" > "$2"
}

STAGEROOT="$X11DIR/linux-build/stage/$XIOS_TARGET_ID/xios-server"
STAGE="$STAGEROOT/root"
PAYLOAD_BIN="$STAGE$XIOS_PACKAGE_PATH_PREFIX$XIOS_SUBPREFIX/bin"
rm -rf "$STAGEROOT"
mkdir -p "$STAGE/DEBIAN" "$PAYLOAD_BIN"
render_template "$TMPL/DEBIAN/control.in" "$STAGE/DEBIAN/control"
render_template "$TMPL/DEBIAN/postinst.in" "$STAGE/DEBIAN/postinst"
render_template "$TMPL/files/usr/bin/xios-server.sh.in" "$PAYLOAD_BIN/xios-server.sh"
chmod 0755 "$STAGE/DEBIAN/postinst" "$PAYLOAD_BIN/xios-server.sh"
cp "$XIOS_SRC" "$PAYLOAD_BIN/Xios"
chmod 0755 "$PAYLOAD_BIN/Xios"

echo "==> staged xios-server for $XIOS_TARGET_ID at $STAGE"
if [ "$STAGE_ONLY" = 1 ]; then
  find "$STAGE" -type f | sed "s#$STAGE/##" | sort
  exit 0
fi

mkdir -p "$PKGOUT"
built="$(xmkdeb "$STAGE" "$PKGOUT")"
echo "==> built $built"
