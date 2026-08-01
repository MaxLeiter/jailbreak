#!/usr/bin/env bash
# Assembles Ladybird.app from an already-built engine (LADYBIRD_ENGINE_STAGE) and
# UI binary (LADYBIRD_UI_BIN), signs it, and packages the deb. Does not build the
# engine itself. The UI binary must be cross-compiled with the same Docker toolchain
# used for the engine build, or the helpers won't link/run against it.
set -euo pipefail
_xt="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ "$_xt" != / ] && [ ! -f "$_xt/linux-build/target-lib.sh" ]; do _xt="$(dirname "$_xt")"; done
. "$_xt/linux-build/target-lib.sh"
xios_load_target "${XIOS_TARGET:-rootless-1900}"

HERE="$(cd "$(dirname "$0")" && pwd)"
X11="$(cd "$HERE/../.." && pwd)"
. "$X11/lib/xlib.sh"

VER="${LADYBIRD_APP_VERSION:-0.1.25+ios1}"
ARCH="$XIOS_DEB_ARCH"
ENGINE_STAGE="${LADYBIRD_ENGINE_STAGE:-}"     # dir with WebContent/RequestServer/... + share/Lagom
UI_BIN="${LADYBIRD_UI_BIN:-}"                 # the built UIKit `Ladybird` Mach-O (step 1 output)
OUT="${OUT:-$HERE/out}"
APP_ENTS="$HERE/entitlements/ladybird-app.entitlements"
HELPER_ENTS="$HERE/entitlements/ladybird-helper.entitlements"

die() { echo "build-ladybird-app: $*" >&2; exit 1; }

# --- Step 1 gate: engine + UI binary must exist ---
if [ -z "$ENGINE_STAGE" ] || [ -z "$UI_BIN" ]; then
    cat >&2 <<EOF
Set:
  LADYBIRD_ENGINE_STAGE=<dir containing WebContent, RequestServer, ImageDecoder,
                         WebWorker, Compositor, and share/Lagom>
  LADYBIRD_UI_BIN=<path to the cross-built UIKit 'Ladybird' Mach-O>
Then re-run.
EOF
    exit 3
fi

STAGE="$(mktemp -d)"
APP="$STAGE$XIOS_PREFIX/Applications/Ladybird.app"
mkdir -p "$APP/share"

# --- Step 2: assemble bundle ---
cp "$UI_BIN" "$APP/Ladybird"
for h in WebContent RequestServer ImageDecoder WebWorker Compositor; do
    [ -f "$ENGINE_STAGE/$h" ] || die "missing helper: $ENGINE_STAGE/$h"
    cp "$ENGINE_STAGE/$h" "$APP/$h"
done
cp -R "$ENGINE_STAGE/share/Lagom" "$APP/share/Lagom"
cp "$HERE/Resources/Info.plist" "$APP/Info.plist"
[ -f "$HERE/Resources/AppIcon.png" ] && cp "$HERE/Resources/AppIcon.png" "$APP/AppIcon.png"
chmod +x "$APP/Ladybird" "$APP/WebContent" "$APP/RequestServer" "$APP/ImageDecoder" "$APP/WebWorker" "$APP/Compositor"

# libiosexec is the one external dylib. Its install name is @rpath-based, so
# give each target its scheme-correct package prefix before signing.
for b in Ladybird WebContent RequestServer ImageDecoder WebWorker Compositor; do
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
for dylib in "$APP"/lib/*.dylib; do
    [ -e "$dylib" ] || break
    for stale_rpath in /var/jb/usr/lib /usr/lib; do
        if [ "$stale_rpath" != "$XIOS_INSTALL_PREFIX/lib" ] && \
           otool -l "$dylib" | grep -A2 LC_RPATH | grep -Fq "path $stale_rpath "; then
            install_name_tool -delete_rpath "$stale_rpath" "$dylib"
        fi
    done
    xsign "$dylib"
done

# --- Step 3: sign (Mac ldid, DER ents; xsign verifies markers) ---
xsign "$APP/Ladybird" "$APP_ENTS" com.apple.private.amfi.can-allow-non-platform
for h in WebContent RequestServer ImageDecoder WebWorker Compositor; do
    xsign "$APP/$h" "$HELPER_ENTS" com.apple.private.amfi.can-allow-non-platform
done

# --- Step 4: control + deb ---
mkdir -p "$STAGE/DEBIAN"
sed -e "s/@VER@/$VER/" \
    -e "s/@ARCH@/$ARCH/" \
    -e "s/@MIN_IOS@/$XIOS_DEFAULT_MIN_IOS/" \
    -e "s/@DEPENDS@/libicu78 (>= 78.3), libiosexec1 (>= 1.3.1)/" \
    "$HERE/DEBIAN/control" > "$STAGE/DEBIAN/control"
sed "s|@APP_INSTALL@|$XIOS_PREFIX/Applications/Ladybird.app|" \
    "$HERE/DEBIAN/postinst" > "$STAGE/DEBIAN/postinst"
cp "$HERE/DEBIAN/postrm" "$STAGE/DEBIAN/postrm"
chmod 0755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/postrm"

mkdir -p "$OUT"
xmkdeb "$STAGE" "$OUT"
echo "built: $OUT (install, then it appears on the home screen after uicache)"
