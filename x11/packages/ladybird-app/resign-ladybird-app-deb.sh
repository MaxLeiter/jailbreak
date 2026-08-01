#!/usr/bin/env bash
# Re-target and re-sign a container-built Ladybird.app deb for one jailbreak
# scheme. The engine payload is generic arm64; XIOS_TARGET controls its install
# path, Debian architecture, libiosexec rpath, and rendered entitlements.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
X11="$(cd "$HERE/../.." && pwd)"
. "$X11/linux-build/target-lib.sh"
xios_load_target "${XIOS_TARGET:-rootless-1900}"
. "$X11/lib/xlib.sh"

IN="${1:-}"
OUT_DIR="${2:-}"
[ -n "$IN" ] && [ -f "$IN" ] || {
    echo "usage: $0 <ladybird-app_..._$XIOS_DEB_ARCH.deb> [out-dir]" >&2
    exit 2
}
IN="$(cd "$(dirname "$IN")" && pwd)/$(basename "$IN")"
OUT_DIR="${OUT_DIR:-$(dirname "$IN")}"

APP_ENTS="$HERE/entitlements/ladybird-app.entitlements"
HELPER_ENTS="$HERE/entitlements/ladybird-helper.entitlements"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/ar" "$WORK/stage/DEBIAN"
(
    cd "$WORK/ar"
    ar x "$IN"
    control_tar="$(ls control.tar.* | head -1)"
    data_tar="$(ls data.tar.* | head -1)"
    tar -xf "$control_tar" -C "$WORK/stage/DEBIAN"
    tar -xf "$data_tar" -C "$WORK/stage"
)

SOURCE_APP=""
for candidate in \
    "$WORK/stage/var/jb/Applications/Ladybird.app" \
    "$WORK/stage/Applications/Ladybird.app"; do
    if [ -d "$candidate" ]; then SOURCE_APP="$candidate"; break; fi
done
[ -n "$SOURCE_APP" ] || { echo "missing Ladybird.app in $IN" >&2; exit 1; }

APP_INSTALL="$XIOS_PREFIX/Applications/Ladybird.app"
APP="$WORK/stage$APP_INSTALL"
if [ "$SOURCE_APP" != "$APP" ]; then
    mkdir -p "$(dirname "$APP")"
    mv "$SOURCE_APP" "$APP"
    rmdir "$WORK/stage/var/jb/Applications" "$WORK/stage/var/jb" "$WORK/stage/var" 2>/dev/null || true
fi

# Every executable imports @rpath/libiosexec.1.dylib. Add the selected scheme's
# library directory before signing; the rootless engine build itself stays reusable.
for b in Ladybird WebContent RequestServer ImageDecoder WebWorker Compositor; do
    [ -f "$APP/$b" ] || { echo "missing binary: $APP/$b" >&2; exit 1; }
    for stale_rpath in /var/jb/usr/lib /usr/lib; do
        if [ "$stale_rpath" != "$XIOS_INSTALL_PREFIX/lib" ] && \
           otool -l "$APP/$b" | grep -A2 LC_RPATH | grep -Fq "path $stale_rpath "; then
            install_name_tool -delete_rpath "$stale_rpath" "$APP/$b"
        fi
    done
    if ! otool -l "$APP/$b" | grep -A2 LC_RPATH | grep -Fq "path $XIOS_INSTALL_PREFIX/lib "; then
        install_name_tool -add_rpath "$XIOS_INSTALL_PREFIX/lib" "$APP/$b"
    fi
done

# The rootless build-base dylibs are otherwise fully bundle-relative, but many
# carry a now-unused /var/jb/usr/lib LC_RPATH. Strip any foreign scheme rpath
# and re-sign every dylib after the load-command mutation.
for dylib in "$APP"/lib/*.dylib; do
    for stale_rpath in /var/jb/usr/lib /usr/lib; do
        if [ "$stale_rpath" != "$XIOS_INSTALL_PREFIX/lib" ] && \
           otool -l "$dylib" | grep -A2 LC_RPATH | grep -Fq "path $stale_rpath "; then
            install_name_tool -delete_rpath "$stale_rpath" "$dylib"
        fi
    done
    xsign "$dylib"
done

xsign "$APP/Ladybird" "$APP_ENTS" \
    com.apple.private.amfi.can-allow-non-platform \
    AGXDeviceUserClient \
    IOSurfaceRootUserClient

for h in WebContent RequestServer ImageDecoder WebWorker Compositor; do
    [ -f "$APP/$h" ] || { echo "missing helper: $APP/$h" >&2; exit 1; }
    xsign "$APP/$h" "$HELPER_ENTS" \
        com.apple.private.amfi.can-allow-non-platform \
        AGXDeviceUserClient \
        IOGPUDeviceUserClient \
        IOSurfaceRootUserClient \
        IOSurfaceAcceleratorClient
done

VERSION="$(awk -F': ' '/^Version:/{print $2; exit}' "$WORK/stage/DEBIAN/control")"
[ -n "$VERSION" ] || { echo "missing package version in $IN" >&2; exit 1; }
sed -e "s/@VER@/$VERSION/" \
    -e "s/@ARCH@/$XIOS_DEB_ARCH/" \
    -e "s/@MIN_IOS@/$XIOS_DEFAULT_MIN_IOS/" \
    -e "s/@DEPENDS@/libiosexec1/" \
    "$HERE/DEBIAN/control" > "$WORK/stage/DEBIAN/control"
sed "s|@APP_INSTALL@|$APP_INSTALL|" \
    "$HERE/DEBIAN/postinst" > "$WORK/stage/DEBIAN/postinst"
cp "$HERE/DEBIAN/postrm" "$WORK/stage/DEBIAN/postrm"
chmod 0755 "$WORK/stage/DEBIAN/postinst" "$WORK/stage/DEBIAN/postrm"
INSTALLED_KB="$(du -sk "$WORK/stage${XIOS_PREFIX:-/Applications}" | awk '{print $1}')"
echo "Installed-Size: $INSTALLED_KB" >> "$WORK/stage/DEBIAN/control"

mkdir -p "$OUT_DIR"
signed="$(xmkdeb "$WORK/stage" "$WORK/out")"
out="$OUT_DIR/$(basename "$signed")"
mv -f "$signed" "$out"
echo "$out"
