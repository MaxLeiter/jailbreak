#!/usr/bin/env bash
set -euo pipefail
_xt="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ "$_xt" != / ] && [ ! -f "$_xt/linux-build/target-lib.sh" ]; do _xt="$(dirname "$_xt")"; done
. "$_xt/linux-build/target-lib.sh"
xios_load_target "${XIOS_TARGET:-rootless-1900}"

PKGDIR="$(cd "$(dirname "$0")" && pwd)"
_x="$PKGDIR"
while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do
  _x="$(dirname "$_x")"
done
. "$_x/lib/xlib.sh"

X11DIR="$(cd "$PKGDIR/../.." && pwd)"
OUT="${OUT:-$X11DIR/linux-build/out}"
VER="${LADYBIRD_WAYLAND_VERSION:-0.1.0+wl4}"
INSTALL_ROOT="${LADYBIRD_WAYLAND_INSTALL_ROOT:-$OUT/ladybird-wayland-install}"
APP_ENTS="$X11DIR/linux-build/build_info/iosc-gpu-client-ent.xml"
ICON_SRC="$X11DIR/packages/ladybird-app/Resources/AppIcon.png"
# Ladybird needs OpenSSL >= 3.5 (EVP_PKEY_sign_message_init); the ladybird-tls
# package ships it privately here so it shadows nothing. Both usr/bin and
# usr/libexec resolve this to $XIOS_PREFIX/usr/lib/ladybird-tls.
TLS_RPATH='@executable_path/../lib/ladybird-tls'

die() { echo "ladybird-wayland build: $*" >&2; exit 1; }

sign_payload() {
  local bin="$1"; shift
  local ents=""
  if [ $# -gt 0 ] && [ -f "$1" ]; then
    ents="$1"
    shift
  fi

  if [ -n "$ents" ] && command -v codesign >/dev/null 2>&1; then
    codesign -s - --force --entitlements "$ents" "$bin" >/dev/null ||
      die "codesign failed on $bin"
  elif [ -n "$ents" ]; then
    xsign "$bin" "$ents" "$@" || die "ldid failed on $bin"
    return 0
  elif xsign "$bin"; then
    return 0
  else
    command -v codesign >/dev/null 2>&1 || die "ldid failed and codesign is unavailable for $bin"
    codesign -s - --force "$bin" >/dev/null ||
      die "codesign failed on $bin"
  fi

  if [ $# -gt 0 ]; then
    local have need
    have="$(codesign -d --entitlements :- "$bin" 2>&1 || true)"
    for need in "$@"; do
      if ! grep -q "$need" <<<"$have"; then
        die "$bin is missing entitlement marker after codesign fallback: $need"
      fi
    done
  fi
  echo "codesign: signed $bin${ents:+ ($ents)}" >&2
}

rewrite_angle_loads() {
  local bin="$1"
  command -v otool >/dev/null 2>&1 || return 0
  command -v install_name_tool >/dev/null 2>&1 || return 0

  if otool -L "$bin" 2>/dev/null | grep -q '@rpath/libGLESv2.2.dylib'; then
    install_name_tool -change @rpath/libGLESv2.2.dylib $XIOS_PREFIX/lib/angle/libGLESv2.dylib "$bin"
  fi
  if otool -L "$bin" 2>/dev/null | grep -q '@rpath/libGLESv2.dylib'; then
    install_name_tool -change @rpath/libGLESv2.dylib $XIOS_PREFIX/lib/angle/libGLESv2.dylib "$bin"
  fi
  if otool -L "$bin" 2>/dev/null | grep -q '@rpath/libEGL.dylib'; then
    install_name_tool -change @rpath/libEGL.dylib $XIOS_PREFIX/lib/angle/libEGL.dylib "$bin"
  fi
  if [ "$(basename "$bin")" = "Compositor" ] &&
     otool -L "$bin" 2>/dev/null | grep -q '/var/jb/lib/angle/libEGL.dylib'; then
    install_name_tool -change $XIOS_PREFIX/lib/angle/libEGL.dylib $XIOS_PREFIX/lib/angle/libEGL.angle.dylib "$bin"
  fi
}

rpaths_of() {
  otool -l "$1" 2>/dev/null |
    awk '/^ *cmd LC_RPATH$/ { f = 1; next } f && /^ *path / { print $2; f = 0 }'
}

# Put ladybird-tls ahead of usr/lib so the private OpenSSL 3.5 wins for
# Ladybird's own binaries and only for those. Without this the @rpath
# libcrypto.3/libssl.3 refs land on the base 3.2.1 and every helper dies with
# "Symbol not found: _EVP_PKEY_sign_message_init". install_name_tool -add_rpath
# only appends, so prepending means deleting the existing rpaths and re-adding
# them behind the private one. MUST run before sign_payload: editing rpaths
# invalidates the signature.
prepend_tls_rpath() {
  local bin="$1" rp first loads
  command -v otool >/dev/null 2>&1 || die "otool is required to fix rpaths on $bin"

  loads="$(otool -L "$bin" 2>/dev/null | grep -E '(libcrypto|libssl)\.3\.dylib' || true)"
  [ -n "$loads" ] || return 0
  if ! grep -qE '@rpath/(libcrypto|libssl)\.3\.dylib' <<<"$loads"; then
    die "$bin links OpenSSL by a path an rpath cannot redirect, so it would load the base 3.2.1: $(tr -s ' \t\n' ' ' <<<"$loads")"
  fi

  command -v install_name_tool >/dev/null 2>&1 ||
    die "install_name_tool is required to fix rpaths on $bin"

  local existing=()
  while IFS= read -r rp; do
    [ -n "$rp" ] && existing+=("$rp")
  done < <(rpaths_of "$bin")

  if [ "${existing[0]:-}" = "$TLS_RPATH" ]; then
    return 0
  fi

  for rp in "${existing[@]}"; do
    install_name_tool -delete_rpath "$rp" "$bin" 2>/dev/null ||
      die "failed to delete rpath $rp from $bin"
  done
  install_name_tool -add_rpath "$TLS_RPATH" "$bin" 2>/dev/null ||
    die "failed to add $TLS_RPATH to $bin"
  for rp in "${existing[@]}"; do
    [ "$rp" = "$TLS_RPATH" ] && continue
    install_name_tool -add_rpath "$rp" "$bin" 2>/dev/null ||
      die "failed to re-add rpath $rp to $bin"
  done

  first="$(rpaths_of "$bin" | head -1)"
  [ "$first" = "$TLS_RPATH" ] ||
    die "$bin still resolves OpenSSL ahead of ladybird-tls (first rpath: ${first:-none})"
  echo "rpath: $(basename "$bin") searches ladybird-tls first" >&2
}

[ -d "$INSTALL_ROOT$XIOS_PREFIX/usr" ] || die "missing install root: $INSTALL_ROOT$XIOS_PREFIX/usr"
[ -f "$APP_ENTS" ] || die "missing app entitlements: $APP_ENTS"
[ -f "$ICON_SRC" ] || die "missing Ladybird icon: $ICON_SRC"

STAGEROOT="$(mktemp -d /private/tmp/ladybird-wayland-stage.XXXXXX)"
trap 'rm -rf "$STAGEROOT"' EXIT
STAGE="$STAGEROOT/ladybird-wayland"
mkdir -p "$STAGE"
cp -a "$INSTALL_ROOT/var" "$STAGE/"

[ -x "$STAGE$XIOS_PREFIX/usr/bin/ladybird" ] || die "installed Ladybird binary missing"

# The iOS Ladybird engine uses its path font provider instead of fontconfig.
# Upstream's installed resource set has no monospace face, so WebContent aborts
# at FontPlugin's fixed-width-font invariant unless we supply the same
# Liberation fallback family used by the standalone Ladybird app. xstage_lagom_fonts
# keeps the checksum pin and the mono-face gate, and shares this staging with the
# .app packaging path, which has the same gap.
echo "==> staging Ladybird text fonts"
xstage_lagom_fonts "$STAGE$XIOS_PREFIX/usr/share/Lagom/fonts" || die "font staging failed"

mkdir -p "$STAGE$XIOS_PREFIX/usr/bin"
cat > "$STAGE$XIOS_PREFIX/usr/bin/ladybird-wayland" <<'EOF'
#!/bin/sh
set -e

export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/usr/local/bin:/var/jb/bin:/var/jb/sbin:$PATH
export HOME="${HOME:-/var/jb/var/root}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/var/jb/tmp}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-/var/jb/tmp/wayland-0}"
export GDK_BACKEND="${GDK_BACKEND:-wayland}"
export GSK_RENDERER="${GSK_RENDERER:-${IOSC_GSK_RENDERER:-ngl}}"
# Ladybird needs OpenSSL 3.5 while the shared runtime provides 3.2.1, but that
# is settled by the ladybird-tls rpath baked into the binaries above, NOT here:
# putting the private prefix on DYLD_LIBRARY_PATH would hand 3.5 to every
# process the browser spawns, which is the sshd/apt shadowing that ladybird-tls
# exists to avoid. /var/jb/usr/lib stays off DYLD_LIBRARY_PATH too, since that
# variable is matched on the leaf name before @rpath is expanded and would
# resolve libcrypto.3/libssl.3 to the base 3.2.1, defeating the rpath. As a
# fallback path it is still searched for anything @rpath cannot resolve, just no
# longer ahead of it.
export DYLD_LIBRARY_PATH="/var/jb/lib/angle${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export DYLD_FALLBACK_LIBRARY_PATH="/var/jb/usr/lib${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
export GSETTINGS_BACKEND="${GSETTINGS_BACKEND:-memory}"
export LC_CTYPE="${LC_CTYPE:-UTF-8}"
export FC_LANG="${FC_LANG:-en}"
export ANGLE_REAL_LIBEGL="${ANGLE_REAL_LIBEGL:-/var/jb/lib/angle/libEGL.angle.dylib}"

if [ "${XIOS_ENABLE_A11Y:-0}" = "1" ] && command -v xios-start-a11y >/dev/null 2>&1; then
  xios-start-a11y >/dev/null 2>&1 || true
elif [ -z "${GTK_A11Y:-}" ]; then
  export GTK_A11Y=none
fi

exec /var/jb/usr/bin/ladybird "$@"
EOF
chmod 0755 "$STAGE$XIOS_PREFIX/usr/bin/ladybird-wayland"

desktop="$STAGE$XIOS_PREFIX/usr/share/applications/org.ladybird.Ladybird.desktop"
if [ -f "$desktop" ]; then
  sed -i '' \
    -e 's|^Exec=.*|Exec=ladybird-wayland --force-new-process %U|' \
    -e 's|^Keywords=.*|Keywords=Browser;Web;Xios;Wayland;|' \
    -e 's|^StartupNotify=.*|StartupNotify=false|' \
    "$desktop"
  perl -0pi -e 's|\[Desktop Action new-window\]\nName=([^\n]*\n)*?Exec=.*|\[Desktop Action new-window\]\nName=New Window\nExec=ladybird-wayland --new-window|s' "$desktop" 2>/dev/null || true
else
  mkdir -p "$STAGE$XIOS_PREFIX/usr/share/applications"
  cat > "$desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Ladybird
GenericName=Web Browser
Comment=Browse the web with Ladybird
Exec=ladybird-wayland --force-new-process %U
Icon=org.ladybird.Ladybird
Terminal=false
Categories=Network;WebBrowser;
Keywords=Browser;Web;Xios;Wayland;
MimeType=text/html;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
StartupNotify=false
Actions=new-window;

[Desktop Action new-window]
Name=New Window
Exec=ladybird-wayland --new-window
EOF
fi
if [ -n "$(tail -c 1 "$desktop" 2>/dev/null || true)" ]; then
  printf '\n' >> "$desktop"
fi

service="$STAGE$XIOS_PREFIX/usr/share/dbus-1/services/org.ladybird.Ladybird.service"
if [ -f "$service" ]; then
  sed -i '' 's|^Exec=.*|Exec=ladybird-wayland --force-new-process|' "$service"
fi

icon_dir="$STAGE$XIOS_PREFIX/usr/share/icons/hicolor/256x256/apps"
mkdir -p "$icon_dir"
install -m 0644 "$ICON_SRC" "$icon_dir/org.ladybird.Ladybird.png"
install -m 0644 "$ICON_SRC" "$icon_dir/ladybird.png"

while IFS= read -r f; do
  rewrite_angle_loads "$f"
  prepend_tls_rpath "$f"
done < <(find "$STAGE$XIOS_PREFIX/usr/bin" "$STAGE$XIOS_PREFIX/usr/libexec" -type f -perm -111 2>/dev/null | sort)

echo "==> signing Ladybird Wayland executables"
sign_payload "$STAGE$XIOS_PREFIX/usr/bin/ladybird" "$APP_ENTS" com.apple.private.amfi.can-allow-non-platform
for helper in WebContent RequestServer ImageDecoder WebWorker Compositor; do
  if [ -f "$STAGE$XIOS_PREFIX/usr/libexec/$helper" ]; then
    # This package runs as an ordinary Wayland client. Keep every helper on the
    # non-platform GPU-client profile: mixing platform-application with the GPU
    # classes creates an incoherent platform-GL signature and is unnecessary
    # outside the standalone UIKit .app flavor.
    sign_payload "$STAGE$XIOS_PREFIX/usr/libexec/$helper" "$APP_ENTS" com.apple.private.amfi.can-allow-non-platform
  fi
done
while IFS= read -r f; do
  sign_payload "$f"
done < <(find "$STAGE$XIOS_PREFIX/usr/lib" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -111 \) 2>/dev/null | sort)

mkdir -p "$STAGE/DEBIAN"
sed "s/@VER@/$VER/g" "$PKGDIR/DEBIAN/control" > "$STAGE/DEBIAN/control"
installed_kb="$(du -sk "$STAGE/var/jb" | cut -f1)"
grep -q '^Installed-Size:' "$STAGE/DEBIAN/control" || echo "Installed-Size: $installed_kb" >> "$STAGE/DEBIAN/control"
cp "$PKGDIR/DEBIAN/postinst" "$STAGE/DEBIAN/postinst"
chmod 0755 "$STAGE/DEBIAN/postinst"

find "$STAGE" -type d -exec chmod 0755 {} +
find "$STAGE" -type f ! -path '*/DEBIAN/postinst' ! -path '*/usr/bin/ladybird' ! -path '*/usr/bin/ladybird-wayland' ! -path '*/usr/libexec/*' -exec chmod 0644 {} +
chmod 0755 "$STAGE$XIOS_PREFIX/usr/bin/ladybird" "$STAGE$XIOS_PREFIX/usr/bin/ladybird-wayland"
find "$STAGE$XIOS_PREFIX/usr/libexec" -type f -exec chmod 0755 {} + 2>/dev/null || true

mkdir -p "$OUT"
built="$(xmkdeb "$STAGE" "$OUT")"
echo "==> built $built"
