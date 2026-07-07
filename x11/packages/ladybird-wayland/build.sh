#!/usr/bin/env bash
set -euo pipefail

PKGDIR="$(cd "$(dirname "$0")" && pwd)"
_x="$PKGDIR"
while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do
  _x="$(dirname "$_x")"
done
. "$_x/lib/xlib.sh"

X11DIR="$(cd "$PKGDIR/../.." && pwd)"
OUT="${OUT:-$X11DIR/linux-build/out}"
VER="${LADYBIRD_WAYLAND_VERSION:-0.1.0+wl1}"
INSTALL_ROOT="${LADYBIRD_WAYLAND_INSTALL_ROOT:-$OUT/ladybird-wayland-install}"
APP_ENTS="$X11DIR/linux-build/build_info/iosc-gpu-client-ent.xml"
HELPER_ENTS="$X11DIR/packages/ladybird-app/entitlements/ladybird-helper.entitlements"
ICON_SRC="$X11DIR/packages/ladybird-app/Resources/AppIcon.png"

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
    install_name_tool -change @rpath/libGLESv2.2.dylib /var/jb/lib/angle/libGLESv2.dylib "$bin"
  fi
  if otool -L "$bin" 2>/dev/null | grep -q '@rpath/libGLESv2.dylib'; then
    install_name_tool -change @rpath/libGLESv2.dylib /var/jb/lib/angle/libGLESv2.dylib "$bin"
  fi
  if otool -L "$bin" 2>/dev/null | grep -q '@rpath/libEGL.dylib'; then
    install_name_tool -change @rpath/libEGL.dylib /var/jb/lib/angle/libEGL.dylib "$bin"
  fi
  if [ "$(basename "$bin")" = "Compositor" ] &&
     otool -L "$bin" 2>/dev/null | grep -q '/var/jb/lib/angle/libEGL.dylib'; then
    install_name_tool -change /var/jb/lib/angle/libEGL.dylib /var/jb/lib/angle/libEGL.angle.dylib "$bin"
  fi
}

[ -d "$INSTALL_ROOT/var/jb/usr" ] || die "missing install root: $INSTALL_ROOT/var/jb/usr"
[ -f "$APP_ENTS" ] || die "missing app entitlements: $APP_ENTS"
[ -f "$HELPER_ENTS" ] || die "missing helper entitlements: $HELPER_ENTS"
[ -f "$ICON_SRC" ] || die "missing Ladybird icon: $ICON_SRC"

STAGEROOT="$(mktemp -d /private/tmp/ladybird-wayland-stage.XXXXXX)"
trap 'rm -rf "$STAGEROOT"' EXIT
STAGE="$STAGEROOT/ladybird-wayland"
mkdir -p "$STAGE"
cp -a "$INSTALL_ROOT/var" "$STAGE/"

[ -x "$STAGE/var/jb/usr/bin/ladybird" ] || die "installed Ladybird binary missing"

mkdir -p "$STAGE/var/jb/usr/bin"
cat > "$STAGE/var/jb/usr/bin/ladybird-wayland" <<'EOF'
#!/bin/sh
set -e

export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/usr/local/bin:/var/jb/bin:/var/jb/sbin:$PATH
export HOME="${HOME:-/var/jb/var/root}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/var/jb/tmp}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-/var/jb/tmp/wayland-0}"
export GDK_BACKEND="${GDK_BACKEND:-wayland}"
export GSK_RENDERER="${GSK_RENDERER:-${IOSC_GSK_RENDERER:-ngl}}"
export DYLD_LIBRARY_PATH="/var/jb/usr/lib:/var/jb/lib/angle${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
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
chmod 0755 "$STAGE/var/jb/usr/bin/ladybird-wayland"

desktop="$STAGE/var/jb/usr/share/applications/org.ladybird.Ladybird.desktop"
if [ -f "$desktop" ]; then
  sed -i '' \
    -e 's|^Exec=.*|Exec=ladybird-wayland --force-new-process %U|' \
    -e 's|^Keywords=.*|Keywords=Browser;Web;Xios;Wayland;|' \
    -e 's|^StartupNotify=.*|StartupNotify=false|' \
    "$desktop"
  perl -0pi -e 's|\[Desktop Action new-window\]\nName=([^\n]*\n)*?Exec=.*|\[Desktop Action new-window\]\nName=New Window\nExec=ladybird-wayland --new-window|s' "$desktop" 2>/dev/null || true
else
  mkdir -p "$STAGE/var/jb/usr/share/applications"
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

service="$STAGE/var/jb/usr/share/dbus-1/services/org.ladybird.Ladybird.service"
if [ -f "$service" ]; then
  sed -i '' 's|^Exec=.*|Exec=ladybird-wayland --force-new-process|' "$service"
fi

icon_dir="$STAGE/var/jb/usr/share/icons/hicolor/256x256/apps"
mkdir -p "$icon_dir"
install -m 0644 "$ICON_SRC" "$icon_dir/org.ladybird.Ladybird.png"
install -m 0644 "$ICON_SRC" "$icon_dir/ladybird.png"

while IFS= read -r f; do
  rewrite_angle_loads "$f"
done < <(find "$STAGE/var/jb/usr/bin" "$STAGE/var/jb/usr/libexec" -type f -perm -111 2>/dev/null | sort)

echo "==> signing Ladybird Wayland executables"
sign_payload "$STAGE/var/jb/usr/bin/ladybird" "$APP_ENTS" com.apple.private.amfi.can-allow-non-platform
for helper in WebContent RequestServer ImageDecoder WebWorker Compositor; do
  if [ -f "$STAGE/var/jb/usr/libexec/$helper" ]; then
    if [ "$helper" = "Compositor" ]; then
      sign_payload "$STAGE/var/jb/usr/libexec/$helper" "$APP_ENTS" com.apple.private.amfi.can-allow-non-platform
    else
      sign_payload "$STAGE/var/jb/usr/libexec/$helper" "$HELPER_ENTS" com.apple.private.amfi.can-allow-non-platform
    fi
  fi
done
while IFS= read -r f; do
  sign_payload "$f"
done < <(find "$STAGE/var/jb/usr/lib" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -111 \) 2>/dev/null | sort)

mkdir -p "$STAGE/DEBIAN"
sed "s/@VER@/$VER/g" "$PKGDIR/DEBIAN/control" > "$STAGE/DEBIAN/control"
installed_kb="$(du -sk "$STAGE/var/jb" | cut -f1)"
grep -q '^Installed-Size:' "$STAGE/DEBIAN/control" || echo "Installed-Size: $installed_kb" >> "$STAGE/DEBIAN/control"
cp "$PKGDIR/DEBIAN/postinst" "$STAGE/DEBIAN/postinst"
chmod 0755 "$STAGE/DEBIAN/postinst"

find "$STAGE" -type d -exec chmod 0755 {} +
find "$STAGE" -type f ! -path '*/DEBIAN/postinst' ! -path '*/usr/bin/ladybird' ! -path '*/usr/bin/ladybird-wayland' ! -path '*/usr/libexec/*' -exec chmod 0644 {} +
chmod 0755 "$STAGE/var/jb/usr/bin/ladybird" "$STAGE/var/jb/usr/bin/ladybird-wayland"
find "$STAGE/var/jb/usr/libexec" -type f -exec chmod 0755 {} + 2>/dev/null || true

mkdir -p "$OUT"
built="$(xmkdeb "$STAGE" "$OUT")"
echo "==> built $built"
