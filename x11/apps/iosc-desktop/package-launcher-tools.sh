#!/usr/bin/env bash
# Package the on-device Xios Home Screen launcher sync tools.
#
# This is the installable path for the native-iPadOS ".desktop app becomes an
# iPad Home Screen app" feature. It ships the tools and shared payloads, then
# starts ioscd. It deliberately does not sync all launchers during postinst; the
# settings UI or an explicit xios-launcher-sync command should choose that.
set -euo pipefail
_xt="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ "$_xt" != / ] && [ ! -f "$_xt/linux-build/target-lib.sh" ]; do _xt="$(dirname "$_xt")"; done
. "$_xt/linux-build/target-lib.sh"
xios_load_target "${XIOS_TARGET:-rootless-1900}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_x="$HERE"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"

REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
X11DIR="$REPO_ROOT/x11"
HOST_DIR="$X11DIR/apps/iosc-host"
OUTDIR="$X11DIR/linux-build/out"
REPODEBS="$REPO_ROOT/repo/debs"
STAGEROOT="/private/tmp/xios-launcher-tools-deb"
STAGE="$STAGEROOT/xios-launcher-tools"
SYSROOT="$STAGEROOT/sysroot"
VER="0.1.3"
ARCH="iphoneos-arm64"
DEB="xios-launcher-tools_${VER}_${ARCH}.deb"

SDK="$(xcrun -sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun -sdk iphoneos -f clang)"
TARGET="arm64-apple-ios16.0"
MIN="-miphoneos-version-min=16.0"
COMMON=(-arch arm64 -target "$TARGET" -isysroot "$SDK" "$MIN" -O2 -Wall)

abs_path() {
  local p="$1"
  printf '%s/%s\n' "$(cd "$(dirname "$p")" && pwd)" "$(basename "$p")"
}

extract_data_tar() {
  local deb="$1" dest="$2" tmp data
  deb="$(abs_path "$deb")"
  tmp="$(mktemp -d "$STAGEROOT/deb.XXXXXX")"
  ( cd "$tmp" && ar x "$deb" )
  data="$(ls "$tmp"/data.tar.* | head -1)"
  case "$data" in
    *.zst) zstdcat "$data" | tar -xf - -C "$dest" ;;
    *.xz)  xzcat "$data"   | tar -xf - -C "$dest" ;;
    *.gz)  gzip -dc "$data" | tar -xf - -C "$dest" ;;
    *)     tar -xf "$data" -C "$dest" ;;
  esac
  rm -rf "$tmp"
}

find_deb() {
  local stem="$1" d f
  for d in "$OUTDIR" "$REPODEBS"; do
    [ -d "$d" ] || continue
    f="$(ls -t "$d/${stem}_"*_iphoneos-arm64.deb 2>/dev/null | head -1 || true)"
    [ -n "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

prepare_pixbuf_sysroot() {
  local stem deb
  rm -rf "$SYSROOT"
  mkdir -p "$SYSROOT" "$STAGEROOT"
  for stem in \
    libgdk-pixbuf-2.0-dev libgdk-pixbuf-2.0-0 \
    libglib2.0-dev libglib2.0-0 \
    libpng16-dev libpng16-16 \
    zlib-dev libgtkintl
  do
    deb="$(find_deb "$stem")" || {
      echo "ERROR: missing $stem deb in $OUTDIR or $REPODEBS" >&2
      exit 1
    }
    echo "   + $(basename "$deb")"
    extract_data_tar "$deb" "$SYSROOT"
  done
}

pixbuf_flags() {
  local raw flag
  raw="$(
    PKG_CONFIG_SYSROOT_DIR="$SYSROOT" \
    PKG_CONFIG_PATH="$SYSROOT$XIOS_PREFIX/usr/lib/pkgconfig:$SYSROOT$XIOS_PREFIX/usr/share/pkgconfig" \
    pkg-config --cflags --libs gdk-pixbuf-2.0
  )"
  for flag in $raw; do
    case "$flag" in
      -lintl)
        printf '%s\n' "-lgtkintl"
        ;;
      -I*)
        [ -d "${flag#-I}" ] && printf '%s\n' "$flag"
        ;;
      -L*)
        [ -d "${flag#-L}" ] && printf '%s\n' "$flag"
        ;;
      *)
        printf '%s\n' "$flag"
        ;;
    esac
  done
}

echo "==> build ioscd and launcher stub"
bash "$HERE/build-stub.sh"

echo "==> build native host payload"
bash "$HOST_DIR/build-host.sh"

echo "==> prepare gdk-pixbuf cross sysroot"
prepare_pixbuf_sysroot

echo "==> compile launcher sync tools"
mkdir -p "$HERE/out"
"$CLANG" "${COMMON[@]}" \
  "$HERE/src/xios-launcher-sync.c" \
  -o "$HERE/out/xios-launcher-sync" \
  -Wl,-rpath,$XIOS_PREFIX/usr/lib

PIXBUF_FLAGS=()
while IFS= read -r flag; do
  PIXBUF_FLAGS+=("$flag")
done < <(pixbuf_flags)
"$CLANG" "${COMMON[@]}" \
  "$HERE/src/xios-icon-render.c" \
  -o "$HERE/out/xios-icon-render" \
  "${PIXBUF_FLAGS[@]}" \
  -Wl,-rpath,$XIOS_PREFIX/usr/lib \
  -lm

xsign "$HERE/out/xios-launcher-sync"
xsign "$HERE/out/xios-icon-render"

echo "==> stage package"
rm -rf "$STAGE"
BIN="$STAGE$XIOS_PREFIX/usr/local/bin"
PAYLOAD="$STAGE$XIOS_PREFIX/usr/libexec/xios-launchers"
LAUNCHD="$STAGE$XIOS_PREFIX/Library/LaunchDaemons"
mkdir -p "$BIN" "$PAYLOAD" "$LAUNCHD" "$STAGE/DEBIAN"

cp "$HERE/out/ioscd" "$BIN/ioscd"
cp "$HERE/out/xios-icon-render" "$BIN/xios-icon-render"
cp "$HERE/out/xios-launcher-sync" "$BIN/xios-launcher-sync"
cp "$HERE/out/IOSCLaunch" "$PAYLOAD/IOSCLaunch"
cp "$HOST_DIR/out/IOSCHost" "$PAYLOAD/IOSCHost"
cp "$HOST_DIR/out/default.metallib" "$PAYLOAD/default.metallib"
cp "$HERE/launcher-ent.xml" "$PAYLOAD/launcher-entitlements.plist"
cp "$HOST_DIR/entitlements.plist" "$PAYLOAD/host-entitlements.plist"
cp "$HERE/ioscd-ent.xml" "$PAYLOAD/ioscd-entitlements.plist"
cp "$HERE/com.max.ioscd.plist" "$LAUNCHD/com.max.ioscd.plist"

chmod 0755 "$BIN/ioscd" "$BIN/xios-icon-render" "$BIN/xios-launcher-sync"
chmod 0755 "$PAYLOAD/IOSCLaunch" "$PAYLOAD/IOSCHost"
chmod 0644 "$PAYLOAD/default.metallib" "$PAYLOAD"/*entitlements.plist
chmod 0644 "$LAUNCHD/com.max.ioscd.plist"

INSTKB="$(du -sk "$STAGE/var" | cut -f1)"

cat > "$STAGE/DEBIAN/control" <<EOF
Package: xios-launcher-tools
Name: Xios Home Screen launcher tools
Version: ${VER}
Architecture: ${ARCH}
Maintainer: Max Leiter <maxwell.leiter@gmail.com>
Author: Max Leiter <maxwell.leiter@gmail.com>
Depends: iosc (>= 0.9.27), xios-session (>= 1.0.56), libgdk-pixbuf-2.0-0, libglib2.0-0, libpng16-16, libgtkintl, libintl8, librsvg2-common, ldid, uikittools
Recommends: com.max.xios, iosc-shell
Section: X11
Priority: optional
Installed-Size: ${INSTKB}
Description: on-device iPad Home Screen app sync for Xios
 xios-launcher-tools lets a jailbroken iPad turn installed freedesktop
 .desktop files into native iPad Home Screen .app bundles for the Xios stack.
 It ships the renderer, launcher sync command, ioscd control daemon, and the
 shared native/classic app payloads used by generated bundles.
 .
 Installing this package starts ioscd but does not create Home Screen apps by
 itself. Use the Xios settings pane or xios-launcher-sync explicitly to list,
 enable, disable, dry-run, and apply launcher sync.
EOF

# Expanding header bakes in the prefix; the body stays quoted so its own shell
# variables and globs reach the device intact.
cat > "$STAGE/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
PREFIX=$XIOS_PREFIX
EOF
cat >> "$STAGE/DEBIAN/postinst" <<'EOF'
PATH=$PREFIX/usr/bin:$PREFIX/usr/sbin:$PREFIX/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

chmod 0755 $PREFIX/usr/local/bin/ioscd \
           $PREFIX/usr/local/bin/xios-icon-render \
           $PREFIX/usr/local/bin/xios-launcher-sync 2>/dev/null || true
chmod 0755 $PREFIX/usr/libexec/xios-launchers/IOSCLaunch \
           $PREFIX/usr/libexec/xios-launchers/IOSCHost 2>/dev/null || true
chmod 0644 $PREFIX/usr/libexec/xios-launchers/default.metallib \
           $PREFIX/usr/libexec/xios-launchers/*entitlements.plist \
           $PREFIX/Library/LaunchDaemons/com.max.ioscd.plist 2>/dev/null || true
chown root:wheel $PREFIX/Library/LaunchDaemons/com.max.ioscd.plist 2>/dev/null || true

if command -v launchctl >/dev/null 2>&1; then
  launchctl bootout system $PREFIX/Library/LaunchDaemons/com.max.ioscd.plist 2>/dev/null || true
  launchctl bootstrap system $PREFIX/Library/LaunchDaemons/com.max.ioscd.plist 2>/dev/null || true
fi

exit 0
EOF

cat > "$STAGE/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
if command -v launchctl >/dev/null 2>&1; then
  launchctl bootout system /var/jb/Library/LaunchDaemons/com.max.ioscd.plist 2>/dev/null || true
fi
exit 0
EOF

chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"

echo "=== staged tree ==="
find "$STAGE" -type f | sed "s#$STAGE##" | sort
echo "installed=${INSTKB}KB"

mkdir -p "$OUTDIR" "$REPODEBS"
built="$(xmkdeb "$STAGE" "$OUTDIR")"
cp "$built" "$REPODEBS/$DEB"

echo "=== DEB BUILT ==="
ls -la "$OUTDIR/$DEB" "$REPODEBS/$DEB"
