#!/usr/bin/env bash
# KDE Plasma session (ROOT). iosc owns the output IOSurface Xios presents;
# kwin_wayland runs nested inside iosc as a QtWayland/ANGLE client and exposes
# its own socket for Plasma clients:
#   iosc compositor -> kwin_wayland --socket kwin-ios-test -> plasmashell
#
# Called by xios-session's KDE presets, or run by hand for diagnosis.
# Set KDE_PLASMA_FLAVOR=desktop|nano|mobile (or pass as $1).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ "${XS_JB+x}" != x ]; then
  case "$SCRIPT_DIR/" in
    /var/jb/*) XS_JB=/var/jb ;;
    *)         XS_JB= ;;
  esac
fi
XS_SUBPREFIX="${XS_SUBPREFIX:-/usr}"
if [ -n "$XS_JB" ]; then
  XS_TMP="${XS_TMP:-$XS_JB/tmp}"
  XS_VAR="${XS_VAR:-$XS_JB/var}"
else
  XS_TMP="${XS_TMP:-${XIOS_RUNTIME_TMP:-/var/tmp}}"
  XS_VAR="${XS_VAR:-${XIOS_RUNTIME_VAR:-/var}}"
fi
XS_PREFIX="${XS_PREFIX:-$XS_JB$XS_SUBPREFIX}"
jb_path() {
  case "$XS_JB" in
    ""|/) printf '%s\n' "$1" ;;
    *)    printf '%s\n' "$XS_JB$1" ;;
  esac
}

export PATH="$XS_PREFIX/local/bin:$XS_PREFIX/bin:$XS_PREFIX/sbin${XS_JB:+:$XS_JB/bin:$XS_JB/sbin}:/usr/bin:/bin:$PATH"
case "${LANG:-}" in ""|UTF-8|*.UTF-8|*.utf8|C.UTF-8) LANG=C ;; esac
case "${LC_CTYPE:-}" in ""|C|POSIX|*.UTF-8|*.utf8|C.UTF-8) LC_CTYPE=UTF-8 ;; esac
export LANG LC_CTYPE
export FC_LANG="${FC_LANG:-en}"
export XCOMPOSEFILE="${XCOMPOSEFILE:-$XS_PREFIX/share/X11/locale/en_US.UTF-8/Compose}"
XIOS_KDE_RUNTIME_SUFFIX="${XIOS_SESSION_SLOT:+-$XIOS_SESSION_SLOT}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$XS_TMP/xios-kde-runtime$XIOS_KDE_RUNTIME_SUFFIX}"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

XIOS_KDE_NOFILE="${XIOS_KDE_NOFILE:-4096}"
case "$XIOS_KDE_NOFILE" in
  ""|*[!0-9]*) ;;
  *)
    if ! ulimit -Sn "$XIOS_KDE_NOFILE" 2>/dev/null; then
      echo "!! could not raise nofile soft limit to $XIOS_KDE_NOFILE; continuing with $(ulimit -Sn 2>/dev/null || echo unknown)"
    fi
    ;;
esac

TMP="$XDG_RUNTIME_DIR"
WSOCK="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
IOSC_BIN="${IOSC_BIN:-$XS_PREFIX/local/bin/iosc}"
KWIN_BIN="${KWIN_BIN:-$(jb_path /Applications/KDE/kwin_wayland.app/kwin_wayland)}"
PLASMA_BIN="${PLASMA_BIN:-$(jb_path /Applications/KDE/plasmashell.app/plasmashell)}"
KAMD_BIN="${KAMD_BIN:-$XS_PREFIX/libexec/kactivitymanagerd}"
KDED_BIN="${KDED_BIN:-$XS_PREFIX/bin/kded6}"
POWERDEVIL_BIN="${POWERDEVIL_BIN:-$XS_PREFIX/libexec/org_kde_powerdevil.app/org_kde_powerdevil}"
LIBEXEC="${LIBEXEC:-$XS_PREFIX/libexec}"
IOS_INPUTD_BIN="${IOS_INPUTD_BIN:-$XS_PREFIX/local/bin/ios-inputd}"
KWIN_SOCKET="${KWIN_SOCKET:-kwin-ios-test}"
KWIN_SOCK_PATH="$XDG_RUNTIME_DIR/$KWIN_SOCKET"
KDE_SESSION_BUS_FILE="$TMP/kde-session-bus${XIOS_SESSION_SLOT:+-$XIOS_SESSION_SLOT}"
KDED_LOG="${KDED_LOG:-$TMP/kded6.log}"
IOSC_LOGICAL="${IOSC_LOGICAL:-1440x1080}"
XIOS_JSON_PATH="${XIOS_JSON_PATH:-$TMP/xios.json}"
IOSC_DDX_SOCK="${IOSC_DDX_SOCK:-$TMP/iosc-ddx.sock}"
IOSC_INPUT_SOCK="${IOSC_INPUT_SOCK:-$TMP/iosc-input.sock}"
IOSC_CLIPBOARD_SOCK="${IOSC_CLIPBOARD_SOCK:-$TMP/iosc-clipboard.sock}"
IOSC_WM_SOCK="${IOSC_WM_SOCK:-$TMP/iosc-wm.sock}"
KDE_KWIN_SIZE_WAS_SET="${KDE_KWIN_SIZE:+x}"
KDE_KWIN_SIZE="${KDE_KWIN_SIZE:-}"
KDE_PLASMA_FLAVOR="${KDE_PLASMA_FLAVOR:-${1:-desktop}}"
ANGLE="${ANGLE:-$(jb_path /lib/angle)}"
KDE_LOG="${KDE_LOG:-$TMP/kde-plasma.log}"
IOSC_LOG="${IOSC_LOG:-$TMP/iosc.log}"
# QT_QUICK_BACKEND is the master switch: while it is "software", Qt ignores
# QSG_RHI_BACKEND entirely, so all three vars below must move together. Use
# ${VAR-} (not ${VAR:-}) so an empty value means "unset, let Qt auto-detect",
# matching the Plasma side.
KWIN_QT_QUICK_BACKEND="${KWIN_QT_QUICK_BACKEND-${QT_QUICK_BACKEND-}}"
KWIN_QSG_RHI_BACKEND="${KWIN_QSG_RHI_BACKEND:-${QSG_RHI_BACKEND:-opengl}}"
KWIN_QMLSCENE_DEVICE="${KWIN_QMLSCENE_DEVICE-${QMLSCENE_DEVICE-}}"
PLASMA_QT_QUICK_BACKEND="${PLASMA_QT_QUICK_BACKEND-${QT_QUICK_BACKEND-}}"
PLASMA_QSG_RHI_BACKEND="${PLASMA_QSG_RHI_BACKEND:-${QSG_RHI_BACKEND:-opengl}}"
PLASMA_QMLSCENE_DEVICE="${PLASMA_QMLSCENE_DEVICE-${QMLSCENE_DEVICE-}}"
PLASMA_QT_WAYLAND_CLIENT_BUFFER_INTEGRATION="${PLASMA_QT_WAYLAND_CLIENT_BUFFER_INTEGRATION:-${QT_WAYLAND_CLIENT_BUFFER_INTEGRATION:-wayland-egl}}"
KDE_QT_QPA_PLATFORMTHEME="${KDE_QT_QPA_PLATFORMTHEME-${QT_QPA_PLATFORMTHEME-}}"
KDE_QT_STYLE_OVERRIDE="${KDE_QT_STYLE_OVERRIDE-${QT_STYLE_OVERRIDE-}}"

if [ -z "$KDE_QT_QPA_PLATFORMTHEME" ] && ls "$XS_PREFIX"/lib/qt6/plugins/platformthemes/KDEPlasmaPlatformTheme6.* >/dev/null 2>&1; then
  KDE_QT_QPA_PLATFORMTHEME=kde
fi
if [ -z "$KDE_QT_STYLE_OVERRIDE" ] && ls "$XS_PREFIX"/lib/qt6/plugins/styles/breeze6.* >/dev/null 2>&1; then
  KDE_QT_STYLE_OVERRIDE=Breeze
fi

size_w() { printf '%s' "$1" | sed -n 's/^\([0-9][0-9]*\)x[0-9][0-9]*$/\1/p'; }
size_h() { printf '%s' "$1" | sed -n 's/^[0-9][0-9]*x\([0-9][0-9]*\)$/\1/p'; }

mobile_kwin_size_from_logical() {
  kwin_size_from_logical_orientation 0 "1080x1440"
}

xios_json_dim() {
  local key="$1"
  sed -n "s/.*\"$key\":[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p" "$XIOS_JSON_PATH" 2>/dev/null | head -1
}

xios_geom_dim() {
  local key="$1" expr
  case "$key" in
    width)  expr='s/.*bounds=\([0-9][0-9]*\)x[0-9][0-9]*.*/\1/p' ;;
    height) expr='s/.*bounds=[0-9][0-9]*x\([0-9][0-9]*\).*/\1/p' ;;
    *) return 0 ;;
  esac
  sed -n "$expr" "$TMP/xios-geom.txt" 2>/dev/null | tail -1
}

kwin_size_from_logical_orientation() {
  local inset="$1" fallback="$2" w h orient_w orient_h tmp min=320
  w="$(size_w "$IOSC_LOGICAL")"
  h="$(size_h "$IOSC_LOGICAL")"
  [ -n "$w" ] && [ -n "$h" ] || { printf '%s\n' "$fallback"; return 0; }

  orient_w="$(xios_geom_dim width)"
  orient_h="$(xios_geom_dim height)"
  if [ -z "$orient_w" ] || [ -z "$orient_h" ]; then
    orient_w="$(xios_json_dim width)"
    orient_h="$(xios_json_dim height)"
  fi
  if [ -n "$orient_w" ] && [ -n "$orient_h" ]; then
    if { [ "$orient_w" -lt "$orient_h" ] && [ "$w" -gt "$h" ]; } || \
       { [ "$orient_w" -gt "$orient_h" ] && [ "$w" -lt "$h" ]; }; then
      tmp="$w"; w="$h"; h="$tmp"
    fi
  fi

  if [ "$inset" -gt 0 ]; then
    w=$((w - inset))
    h=$((h - inset))
    [ "$w" -ge "$min" ] || w="$min"
    [ "$h" -ge "$min" ] || h="$min"
  fi
  printf '%sx%s\n' "$w" "$h"
}

desktop_kwin_size_from_logical() {
  local inset="${XIOS_KDE_DESKTOP_INSET:-80}" min=320 scale="${XIOS_KDE_OUTPUT_SCALE:-2}"
  local raw_w raw_h w h
  raw_w="$(xios_json_dim width)"
  raw_h="$(xios_json_dim height)"
  if [ -n "$raw_w" ] && [ -n "$raw_h" ] && [ "$scale" -gt 0 ] 2>/dev/null; then
    w=$((raw_w / scale))
    h=$((raw_h / scale))
    if [ "$inset" -gt 0 ]; then
      w=$((w - inset))
      h=$((h - inset))
      [ "$w" -ge "$min" ] || w="$min"
      [ "$h" -ge "$min" ] || h="$min"
    fi
    printf '%sx%s\n' "$w" "$h"
    return 0
  fi
  kwin_size_from_logical_orientation "$inset" "1360x1000"
}

PLASMA_ENV=()
KDE_PLASMA_LABEL="KDE Plasma"
KDE_QT_QUICK_CONTROLS_STYLE="${KDE_QT_QUICK_CONTROLS_STYLE:-org.kde.desktop}"
case "$KDE_PLASMA_FLAVOR" in
  desktop|plasma|kde)
    KDE_PLASMA_FLAVOR=desktop
    KDE_PLASMA_LABEL="KDE Plasma Desktop"
    PLASMA_SHELL_PLUGIN="${PLASMA_SHELL_PLUGIN:-org.kde.plasma.desktop}"
    ;;
  nano|plasma-nano|kde-nano)
    KDE_PLASMA_FLAVOR=nano
    KDE_PLASMA_LABEL="KDE Plasma Nano"
    PLASMA_SHELL_PLUGIN=
    PLASMA_ENV+=(PLASMA_DEFAULT_SHELL="${PLASMA_DEFAULT_SHELL:-org.kde.plasma.nano}")
    ;;
  mobile|phone|plasma-mobile|kde-mobile)
    KDE_PLASMA_FLAVOR=mobile
    KDE_PLASMA_LABEL="KDE Plasma Mobile"
    PLASMA_SHELL_PLUGIN=
    PLASMA_ENV+=(PLASMA_DEFAULT_SHELL="${PLASMA_DEFAULT_SHELL:-org.kde.plasma.mobileshell}")
    PLASMA_ENV+=(PLASMA_PLATFORM="${PLASMA_PLATFORM:-phone:handset}")
    PLASMA_ENV+=(QT_QUICK_CONTROLS_MOBILE="${QT_QUICK_CONTROLS_MOBILE:-true}")
    PLASMA_ENV+=(PLASMA_INTEGRATION_USE_PORTAL="${PLASMA_INTEGRATION_USE_PORTAL:-1}")
    ;;
  *)
    echo "!! invalid KDE_PLASMA_FLAVOR=$KDE_PLASMA_FLAVOR, expected desktop|nano|mobile"
    exit 2
    ;;
esac

IOSC_FULLSCREEN_TOPLEVELS="${IOSC_FULLSCREEN_TOPLEVELS-}"
if { [ "$KDE_PLASMA_FLAVOR" = desktop ] || [ "$KDE_PLASMA_FLAVOR" = mobile ]; } && [ -z "$IOSC_FULLSCREEN_TOPLEVELS" ]; then
  IOSC_FULLSCREEN_TOPLEVELS=1
fi
IOSC_NO_OUTPUT_TRANSFORM="${IOSC_NO_OUTPUT_TRANSFORM-}"
if [ "$KDE_PLASMA_FLAVOR" = mobile ] && [ -z "$IOSC_NO_OUTPUT_TRANSFORM" ]; then
  IOSC_NO_OUTPUT_TRANSFORM=1
fi

IOSC_LOGICAL_W="$(size_w "$IOSC_LOGICAL")"
IOSC_LOGICAL_H="$(size_h "$IOSC_LOGICAL")"

[ -x "$IOSC_BIN" ] || { echo "!! $IOSC_BIN missing/not executable"; exit 1; }
[ -x "$KWIN_BIN" ] || { echo "!! $KWIN_BIN missing/not executable"; exit 1; }
[ -x "$PLASMA_BIN" ] || { echo "!! $PLASMA_BIN missing/not executable"; exit 1; }
[ -n "$IOSC_LOGICAL_W" ] && [ -n "$IOSC_LOGICAL_H" ] || {
  echo "!! invalid IOSC_LOGICAL=$IOSC_LOGICAL, expected WxH"
  exit 2
}
if [ -n "$KDE_KWIN_SIZE_WAS_SET" ]; then
  [ -n "$(size_w "$KDE_KWIN_SIZE")" ] && [ -n "$(size_h "$KDE_KWIN_SIZE")" ] || {
    echo "!! invalid KDE_KWIN_SIZE=$KDE_KWIN_SIZE, expected WxH"
    exit 2
  }
fi

kde_process_running() {
  ps ax | grep -v grep | grep -E "$1" >/dev/null 2>&1
}

if [ -z "${XIOS_SESSION_SLOT:-}" ]; then
  echo "==> stop prior iosc/KDE session pieces (keep the Xios display app)"
  ps ax | grep -v grep | grep -E "(^|[ /])iosc( |$)|ioscbg|ioscbar|ioscdock|ioscoverview|kwin_wayland|plasmashell|plasmawindowed|kactivitymanagerd|kded6|dbus-daemon.*--session|dbus-run-session" \
    | awk '{print $1}' | while read -r pid; do
        [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ] || kill -TERM "$pid" 2>/dev/null
    done
  sleep 1
  ps ax | grep -v grep | grep -E "ioscbg|ioscbar|ioscdock|ioscoverview|kwin_wayland|plasmashell|plasmawindowed|kded6" \
    | awk '{print $1}' | while read -r pid; do
        [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ] || kill -9 "$pid" 2>/dev/null
    done
fi

rm -f "$WSOCK" "$WSOCK.lock" "$KWIN_SOCK_PATH" "$KWIN_SOCK_PATH.lock" \
      "$IOSC_DDX_SOCK" "$IOSC_INPUT_SOCK" "$IOSC_CLIPBOARD_SOCK" \
      "$IOSC_WM_SOCK" "$XIOS_JSON_PATH" "$KDE_SESSION_BUS_FILE" \
      "$IOSC_LOG" "$KDE_LOG" "$KDED_LOG" 2>/dev/null || true

echo "==> validate package-owned ANGLE aliases and GSettings schemas"
for f in libGLESv2.so.2 libGLESv2.so libEGL.so.1 libEGL.so; do
  [ -e "$ANGLE/$f" ] || { echo "!! missing $ANGLE/$f — reinstall the angle package"; exit 1; }
done
[ -e "$XS_PREFIX/share/glib-2.0/schemas/gschemas.compiled" ] || {
  echo "!! compiled GSettings schema cache missing — reinstall the owning package"
  exit 1
}

kde_app_support_link() {
  local name="$1"
  local target="$XS_PREFIX/share/$name"
  local base link
  [ -e "$target" ] || return 0
  for base in "$XS_VAR/root/Library/Application Support" "/var/root/Library/Application Support"; do
    mkdir -p "$base"
    link="$base/$name"
    if [ -L "$link" ]; then
      ln -sfn "$target" "$link" 2>/dev/null || true
    elif [ ! -e "$link" ]; then
      ln -s "$target" "$link" 2>/dev/null || true
    else
      echo "!! $link already exists; leaving it in place"
    fi
  done
}

kde_config_link() {
  local name="$1"
  local target="$2"
  local base link
  [ -e "$target" ] || return 0
  for base in "$XS_VAR/root/Library/Preferences" "/var/root/Library/Preferences"; do
    mkdir -p "$base"
    link="$base/$name"
    if [ -L "$link" ]; then
      ln -sfn "$target" "$link" 2>/dev/null || true
    elif [ ! -e "$link" ]; then
      ln -s "$target" "$link" 2>/dev/null || true
    else
      echo "!! $link already exists; leaving it in place"
    fi
  done
}

kde_ini_has_key() {
  local file="$1" group="$2" key="$3"
  [ -f "$file" ] || return 1
  awk -v group="[$group]" -v key="$key" '
    $0 == group { in_group = 1; next }
    /^\[/ { in_group = 0 }
    in_group && index($0, key "=") == 1 { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$file"
}

kde_ini_set_if_missing() {
  local file="$1" group="$2" key="$3" value="$4"
  mkdir -p "$(dirname "$file")"
  [ -e "$file" ] || : >"$file"
  kde_ini_has_key "$file" "$group" "$key" && return 0
  {
    printf '\n[%s]\n' "$group"
    printf '%s=%s\n' "$key" "$value"
  } >>"$file"
}

# A stale [QtQuickRendererSettings] SceneGraphBackend=software pin makes
# plasmashell draw through Qt's shm backingstore instead of ANGLE, which
# commits one frame and then stops -- black screen. Drop it here; set
# XIOS_KDE_FORCE_SOFTWARE_QTQUICK=1 to keep it (useful to isolate a GL fault).
kde_unpin_software_qtquick() {
  [ "${XIOS_KDE_FORCE_SOFTWARE_QTQUICK:-0}" = 0 ] || return 0
  local file
  for file in \
    "$XS_VAR/root/Library/Preferences/kdeglobals" \
    "/var/root/Library/Preferences/kdeglobals"; do
    [ -f "$file" ] || continue
    kde_ini_has_key "$file" QtQuickRendererSettings SceneGraphBackend || continue
    cp -p "$file" "$file.before-xios-qtquick-unpin" 2>/dev/null || true
    awk '
      $0 == "[QtQuickRendererSettings]" { in_group = 1; next }
      /^\[/ { in_group = 0 }
      in_group && index($0, "SceneGraphBackend=") == 1 { next }
      { print }
    ' "$file" >"$file.xios-tmp" && mv "$file.xios-tmp" "$file"
    echo "kde: dropped SceneGraphBackend=software pin from $file (QtQuick -> ANGLE)"
  done
}

# Setting [General] ColorScheme=<name> in kdeglobals does nothing by itself --
# titlebar/widget colours come from the [WM]/[Colors:*] groups, which must be
# copied in from the scheme file directly. Leave other keys alone.
kde_apply_color_scheme() {
  local scheme="$1" file="$2" src want have tmp
  src="$XS_PREFIX/share/color-schemes/$scheme.colors"
  [ -f "$src" ] || return 0
  mkdir -p "$(dirname "$file")"
  [ -e "$file" ] || : >"$file"
  # Idempotent: the scheme's own [WM] background is the fingerprint.
  want="$(awk '/^\[WM\]/{f=1;next} /^\[/{f=0} f && /^activeBackground=/{print; exit}' "$src")"
  have="$(awk '/^\[WM\]/{f=1;next} /^\[/{f=0} f && /^activeBackground=/{print; exit}' "$file")"
  [ -n "$want" ] && [ "$want" = "$have" ] && return 0
  tmp="$file.xios-colors-tmp"
  awk '/^\[/ { drop = ($0 ~ /^\[(WM\]|Colors:|ColorEffects:)/) } !drop { print }' "$file" >"$tmp" || return 0
  awk '/^\[/ { keep = ($0 ~ /^\[(WM\]|Colors:|ColorEffects:)/) } keep { print }' "$src" >>"$tmp" || return 0
  mv "$tmp" "$file"
  echo "kde: applied $scheme colour groups to $(basename "$file") (titlebars follow the scheme)"
}

kde_seed_desktop_style_config() {
  [ "$KDE_PLASMA_FLAVOR" = desktop ] || return 0
  local file
  kde_unpin_software_qtquick
  for file in \
    "$XS_VAR/root/Library/Preferences/kdeglobals" \
    "/var/root/Library/Preferences/kdeglobals"; do
    kde_ini_set_if_missing "$file" KDE LookAndFeelPackage org.kde.breezedark.desktop
    kde_ini_set_if_missing "$file" Icons Theme breeze-dark
    if [ -f "$XS_PREFIX/share/color-schemes/BreezeDark.colors" ]; then
      kde_ini_set_if_missing "$file" General ColorScheme BreezeDark
      kde_ini_set_if_missing "$file" General Name "Breeze Dark"
      kde_apply_color_scheme BreezeDark "$file"
    fi
    if ls "$XS_PREFIX"/lib/qt6/plugins/styles/breeze6.* >/dev/null 2>&1; then
      kde_ini_set_if_missing "$file" KDE widgetStyle Breeze
    fi
  done
}

kde_desktop_favorites_value() {
  local id path ids="" sep=""
  for id in org.kde.kwrite.desktop org.kde.gwenview.desktop org.kde.ark.desktop systemsettings.desktop; do
    for path in \
      "$XS_PREFIX/share/applications/$id" \
      "$XS_PREFIX/local/share/applications/$id"; do
      if [ -f "$path" ]; then
        ids="$ids$sep$id"
        sep=","
        break
      fi
    done
  done
  [ -n "$ids" ] || ids="org.kde.kwrite.desktop,org.kde.gwenview.desktop,org.kde.ark.desktop"
  printf '%s\n' "$ids"
}

kde_backup_user_config() {
  local file="$1" stamp
  [ -f "$file" ] || return 0
  stamp="$(date '+%Y%m%d-%H%M%S' 2>/dev/null || echo now)"
  cp -p "$file" "$file.before-xios-favorites-migration-$stamp" 2>/dev/null || true
}

kde_desktop_layout_has_stale_applets() {
  local file="$1"
  [ -f "$file" ] || return 1
  grep -F "[Containments][1][Applets]" "$file" >/dev/null 2>&1 || return 1
  grep -F "[Containments][2]" "$file" >/dev/null 2>&1 || return 1
  grep -Eq '^plugin=org\.kde\.plasma\.(kickoff|kicker|notifications|systemtray)$' "$file" 2>/dev/null
}

kde_migrate_desktop_user_config() {
  [ "$KDE_PLASMA_FLAVOR" = desktop ] || return 0
  [ "${XIOS_KDE_MIGRATE_STALE_FAVORITES:-1}" != 0 ] || return 0

  local stale_re='preferred://browser|org\.kde\.(kontact|dolphin|discover)(\.desktop)?'
  local favorites fav1 fav2 fav3 file tmp
  favorites="$(kde_desktop_favorites_value)"
  IFS=, read -r fav1 fav2 fav3 _rest <<EOF
$favorites
EOF
  fav1="${fav1:-org.kde.kwrite.desktop}"
  fav2="${fav2:-$fav1}"
  fav3="${fav3:-$fav2}"

  for file in \
    "$XS_VAR/root/Library/Preferences/plasma-org.kde.plasma.desktop-appletsrc" \
    "/var/root/Library/Preferences/plasma-org.kde.plasma.desktop-appletsrc"; do
    [ -f "$file" ] || continue
    if kde_desktop_layout_has_stale_applets "$file"; then
      kde_backup_user_config "$file"
      rm -f "$file"
      echo "   reset stale Plasma Desktop applet layout: $file"
      continue
    fi
    grep -Eq "$stale_re" "$file" 2>/dev/null || continue
    kde_backup_user_config "$file"
    tmp="$file.xios-migrate.$$"
    if awk -v favorites="$favorites" '
      /^favoriteApps=/ { print "favoriteApps=" favorites; next }
      { print }
    ' "$file" >"$tmp"; then
      mv "$tmp" "$file"
      echo "   migrated stale Plasma Desktop favorites: $file -> $favorites"
    else
      rm -f "$tmp" 2>/dev/null || true
    fi
  done

  for file in \
    "$XS_VAR/root/Library/Preferences/kactivitymanagerd-statsrc" \
    "/var/root/Library/Preferences/kactivitymanagerd-statsrc"; do
    [ -f "$file" ] || continue
    grep -Eq "$stale_re" "$file" 2>/dev/null || continue
    kde_backup_user_config "$file"
    tmp="$file.xios-migrate.$$"
    if sed \
      -e "s|preferred://browser|$fav1|g" \
      -e "s|org.kde.kontact.desktop|$fav1|g" \
      -e "s|org.kde.dolphin.desktop|$fav2|g" \
      -e "s|org.kde.discover.desktop|$fav3|g" \
      -e "s|org.kde.discover|$fav3|g" \
      "$file" >"$tmp"; then
      mv "$tmp" "$file"
      echo "   migrated stale KDE activity favorites: $file"
    else
      rm -f "$tmp" 2>/dev/null || true
    fi
  done
}

kde_seed_mobile_wallpaper_config() {
  [ "$KDE_PLASMA_FLAVOR" = mobile ] || return 0
  local file id tmp seen=0 wallpaper="file:///var/jb/usr/share/backgrounds/xios/xios-default.png"
  local old_wallpaper="file:///var/jb/usr/share/backgrounds/xios/xios-default.jpg"
  for file in \
    "$XS_VAR/root/Library/Preferences/plasma-org.kde.plasma.mobileshell-appletsrc" \
    "/var/root/Library/Preferences/plasma-org.kde.plasma.mobileshell-appletsrc"; do
    [ -f "$file" ] || continue
    if grep -q "$old_wallpaper" "$file" 2>/dev/null; then
      tmp="$file.xios-wallpaper.$$"
      sed "s|$old_wallpaper|$wallpaper|g" "$file" >"$tmp" && mv "$tmp" "$file"
      rm -f "$tmp" 2>/dev/null || true
      echo "   migrated Mobile wallpaper config to PNG: $file"
    fi
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      seen=1
      if awk -v id="$id" '
        $0 == "[Containments][" id "][Wallpaper][org.kde.image][General]" { in_group = 1; next }
        /^\[/ { in_group = 0 }
        in_group && /^Image=/ { found = 1 }
        END { exit found ? 0 : 1 }
      ' "$file"; then
        continue
      fi
      {
        printf '\n[Containments][%s][Wallpaper][org.kde.image][General]\n' "$id"
        printf 'FillMode=2\n'
        printf 'Image=%s\n' "$wallpaper"
        printf 'PreviewImage=%s\n' "$wallpaper"
      } >>"$file"
      echo "   seeded Mobile wallpaper config: $file containment $id"
    done <<EOF
$(awk '
  /^\[Containments\]\[[0-9][0-9]*\]$/ {
    id = $0
    sub(/^\[Containments\]\[/, "", id)
    sub(/\]$/, "", id)
    next
  }
  /^plugin=org\.kde\.plasma\.mobile\.homescreen\./ && id != "" {
    print id
  }
' "$file")
EOF
  done
  [ "$seen" = 1 ] || true
}

kde_mobile_folio_favourites_value() {
  local favorites oldifs id out="" sep=""
  favorites="$(kde_desktop_favorites_value)"
  oldifs="$IFS"
  IFS=,
  set -- $favorites
  IFS="$oldifs"
  for id in "$@"; do
    [ -n "$id" ] || continue
    out="$out$sep{\"storageId\":\"$id\",\"type\":\"application\"}"
    sep=","
  done
  printf '[%s]\n' "$out"
}

kde_mobile_folio_pages_value() {
  local favorites oldifs id out="" sep="" col=0
  favorites="$(kde_desktop_favorites_value)"
  oldifs="$IFS"
  IFS=,
  set -- $favorites
  IFS="$oldifs"
  for id in "$@"; do
    [ -n "$id" ] || continue
    out="$out$sep{\"column\":$col,\"row\":0,\"storageId\":\"$id\",\"type\":\"application\"}"
    sep=","
    col=$((col + 1))
  done
  printf '[[%s]]\n' "$out"
}

kde_mobile_folio_has_pages() {
  local file="$1" id="$2"
  awk -v id="$id" '
    $0 == "[Containments][" id "]" { in_group = 1; next }
    /^\[/ { in_group = 0 }
    in_group && /^Pages=/ {
      value = substr($0, 7)
      gsub(/[[:space:]]/, "", value)
      if (value != "" && value != "[]" && value != "[[]]") found = 1
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

kde_seed_mobile_folio_config() {
  [ "$KDE_PLASMA_FLAVOR" = mobile ] || return 0
  [ "${XIOS_KDE_SEED_MOBILE_FOLIO:-1}" != 0 ] || return 0
  local file id tmp favourites pages
  favourites="$(kde_mobile_folio_favourites_value)"
  pages="$(kde_mobile_folio_pages_value)"

  for file in \
    "$XS_VAR/root/Library/Preferences/plasma-org.kde.plasma.mobileshell-appletsrc" \
    "/var/root/Library/Preferences/plasma-org.kde.plasma.mobileshell-appletsrc"; do
    [ -f "$file" ] || continue
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      kde_mobile_folio_has_pages "$file" "$id" && continue
      kde_backup_user_config "$file"
      tmp="$file.xios-folio.$$"
      if awk -v id="$id" -v favourites="$favourites" -v pages="$pages" '
        function seed() {
          print "Favourites=" favourites
          print "Pages=" pages
          print "homeScreenRows=5"
          print "homeScreenColumns=4"
          print "delegateIconSize=64"
          print "showPagesAppLabels=true"
          print "showFavoritesAppLabels=true"
          print "showFavoritesBarBackground=true"
          print "showWallpaperBlur=false"
          inserted = 1
        }
        $0 == "[Containments][" id "]" {
          print
          in_group = 1
          next
        }
        in_group && /^\[/ {
          if (!inserted) {
            seed()
          }
          in_group = 0
          print
          next
        }
        in_group && /^(Favourites|Pages|homeScreenRows|homeScreenColumns|delegateIconSize|showPagesAppLabels|showFavoritesAppLabels|showFavoritesBarBackground|showWallpaperBlur)=/ {
          next
        }
        { print }
        END {
          if (in_group && !inserted) {
            seed()
          }
        }
      ' "$file" >"$tmp"; then
        mv "$tmp" "$file"
        echo "   seeded Mobile Folio app grid: $file containment $id"
      else
        rm -f "$tmp" 2>/dev/null || true
      fi
    done <<EOF
$(awk '
  /^\[Containments\]\[[0-9][0-9]*\]$/ {
    id = $0
    sub(/^\[Containments\]\[/, "", id)
    sub(/\]$/, "", id)
    next
  }
  /^plugin=org\.kde\.plasma\.mobile\.homescreen\.folio$/ && id != "" {
    print id
  }
' "$file")
EOF
  done
}

if [ "${XIOS_KDE_APP_SUPPORT_BRIDGE:-1}" != 0 ]; then
  echo "==> bridge Qt/KPackage Darwin app-data paths to $XS_PREFIX/share"
  for name in plasma icons color-schemes applications metainfo mime kservices6 knotifications6 kglobalaccel kpackage dbus-1 krunner qlogging-categories6; do
    kde_app_support_link "$name"
  done
  kde_config_link menus "$(jb_path /etc/xdg/menus)"
fi
kde_seed_mobile_wallpaper_config
kde_seed_mobile_folio_config
kde_seed_desktop_style_config
kde_migrate_desktop_user_config

if [ -n "${XIOS_KDE_NO_KAMD+x}" ]; then
  case "$XIOS_KDE_NO_KAMD" in
    0|false|FALSE|no|NO) ;;
    *) PLASMA_ENV+=(XIOS_KDE_NO_KAMD="$XIOS_KDE_NO_KAMD") ;;
  esac
elif [ ! -x "$KAMD_BIN" ]; then
  echo "!! $KAMD_BIN missing; enabling first-light KActivities bypass"
  PLASMA_ENV+=(XIOS_KDE_NO_KAMD=1)
fi

PULSE_PROFILE="$(jb_path /etc/profile.d/xios-pulse.sh)"
[ -r "$PULSE_PROFILE" ] && . "$PULSE_PROFILE" && xios_pulse_start

SETSID="$(command -v setsid || true)"
if [ -z "$SETSID" ]; then
  SETSID="$TMP/xsetsid"
  cat > "$SETSID" <<PYEOF
#!$XS_PREFIX/bin/python3
import os, sys
try:
    os.setsid()
except OSError:
    if os.fork() > 0:
        os._exit(0)
    os.setsid()
os.execvp(sys.argv[1], sys.argv[1:])
PYEOF
  chmod +x "$SETSID"
fi

echo "==> start iosc output compositor (logical $IOSC_LOGICAL) -> $IOSC_LOG"
nohup "$SETSID" env \
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
  IOSC_IGNORE_ACTIVE_SESSION=1 \
  IOSC_DEBUG="${IOSC_DEBUG-}" \
  IOSC_FULLSCREEN_TOPLEVELS="$IOSC_FULLSCREEN_TOPLEVELS" \
  IOSC_NO_OUTPUT_TRANSFORM="$IOSC_NO_OUTPUT_TRANSFORM" \
  "$IOSC_BIN" -logical "$IOSC_LOGICAL" -s "$WAYLAND_DISPLAY" \
    -ddx-sock "$IOSC_DDX_SOCK" -json "$XIOS_JSON_PATH" \
    -input-sock "$IOSC_INPUT_SOCK" -clipboard-sock "$IOSC_CLIPBOARD_SOCK" \
    -wm-sock "$IOSC_WM_SOCK" >"$IOSC_LOG" 2>&1 </dev/null &
ICPID=$!

for _ in $(seq 1 50); do
  [ -S "$WSOCK" ] && [ -n "$(xios_json_dim width)" ] && [ -n "$(xios_json_dim height)" ] && break
  kill -0 "$ICPID" 2>/dev/null || break
  sleep 0.2
done
if ! kill -0 "$ICPID" 2>/dev/null; then
  echo "!! iosc died:"
  sed 's/^/   /' "$IOSC_LOG" 2>/dev/null
  exit 1
fi
[ -S "$WSOCK" ] || { echo "!! iosc did not create $WSOCK"; exit 1; }

if chown mobile:mobile "$IOSC_DDX_SOCK" 2>/dev/null || chown 501:501 "$IOSC_DDX_SOCK" 2>/dev/null; then
  chmod 0660 "$IOSC_DDX_SOCK" 2>/dev/null
else
  chmod 0600 "$IOSC_DDX_SOCK" 2>/dev/null
  echo "!! could not hand $IOSC_DDX_SOCK to mobile; keeping it owner-only"
fi

if [ "$KDE_PLASMA_FLAVOR" = mobile ]; then
  before_w="$(xios_json_dim width)"
  before_h="$(xios_json_dim height)"
  if [ -z "${XIOS_SESSION_SLOT:-}" ] || [ "${XIOS_SLOT_FOREGROUND:-0}" = 1 ]; then
    echo "==> foreground Xios app before KWin so Mobile sees the rotated output"
    uiopen -b com.max.xios 2>/dev/null || uiopen com.max.xios 2>/dev/null || true
    for _ in $(seq 1 40); do
      cur_w="$(xios_json_dim width)"
      cur_h="$(xios_json_dim height)"
      [ -n "$cur_w" ] && [ -n "$cur_h" ] || { sleep 0.25; continue; }
      if [ "$before_w" != "$cur_w" ] || [ "$before_h" != "$cur_h" ] || [ "$cur_h" -gt "$cur_w" ]; then
        break
      fi
      sleep 0.25
    done
  else
    echo "==> slot $XIOS_SESSION_SLOT: skipping Xios foreground before KWin"
  fi
  echo "   iosc output before KWin: $(cat "$XIOS_JSON_PATH" 2>/dev/null)"
fi

if [ -z "$KDE_KWIN_SIZE_WAS_SET" ]; then
  case "$KDE_PLASMA_FLAVOR" in
    mobile) KDE_KWIN_SIZE="$(mobile_kwin_size_from_logical)" ;;
    *)      KDE_KWIN_SIZE="$(desktop_kwin_size_from_logical)" ;;
  esac
fi
KWIN_W="${KDE_KWIN_SIZE%x*}"
KWIN_H="${KDE_KWIN_SIZE#*x}"

echo "==> launch KWin + plasmashell ($KDE_PLASMA_LABEL) in one session bus -> $KDE_LOG"
echo "   KWin logical size: ${KWIN_W}x${KWIN_H}"
echo "   nofile soft limit: $(ulimit -Sn 2>/dev/null || echo unknown)"
nohup "$SETSID" env \
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
  WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
  KWIN_BIN="$KWIN_BIN" \
  PLASMA_BIN="$PLASMA_BIN" \
  KAMD_BIN="$KAMD_BIN" \
  KDED_BIN="$KDED_BIN" \
  POWERDEVIL_BIN="$POWERDEVIL_BIN" \
  XIOS_KDE_START_POWERDEVIL="${XIOS_KDE_START_POWERDEVIL:-1}" \
  KDED_LOG="$KDED_LOG" \
  LIBEXEC="$LIBEXEC" \
  KWIN_SOCKET="$KWIN_SOCKET" \
  KWIN_W="$KWIN_W" \
  KWIN_H="$KWIN_H" \
  IOS_INPUTD_BIN="$IOS_INPUTD_BIN" \
  IOSC_INPUT_SOCK="$IOSC_INPUT_SOCK" \
  KDE_AUTO_KEYBOARD="${KDE_AUTO_KEYBOARD:-1}" \
  KDE_SESSION_BUS_FILE="$KDE_SESSION_BUS_FILE" \
  XIOS_SESSION_STATUS_FILE="${XIOS_SESSION_STATUS_FILE:-}" \
  XIOS_SESSION_STATUS_PRESET="${XIOS_SESSION_STATUS_PRESET:-}" \
  PLASMA_SHELL_PLUGIN="${PLASMA_SHELL_PLUGIN:-}" \
  PLASMA_NO_RESPAWN="${PLASMA_NO_RESPAWN:-1}" \
  DYLD_LIBRARY_PATH="$XS_PREFIX/lib:$ANGLE" \
  XDG_DATA_DIRS="$XS_PREFIX/share" \
  XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$XS_VAR/root/.config}" \
  XDG_CONFIG_DIRS="$(jb_path /etc/xdg):$XS_PREFIX/etc/xdg" \
  GSETTINGS_SCHEMA_DIR="$XS_PREFIX/share/glib-2.0/schemas" \
  HOME="$XS_VAR/root" \
  KDE_FULL_SESSION=true \
  KDE_SESSION_VERSION=6 \
  XDG_CURRENT_DESKTOP=KDE \
  XDG_SESSION_TYPE=wayland \
  QT_QPA_PLATFORM=wayland \
  QT_PLUGIN_PATH="$XS_PREFIX/lib/qt6/plugins" \
  QML2_IMPORT_PATH="$XS_PREFIX/lib/qt6/qml" \
  QML_IMPORT_PATH="$XS_PREFIX/lib/qt6/qml" \
  KWIN_QT_QUICK_BACKEND="$KWIN_QT_QUICK_BACKEND" \
  KWIN_QSG_RHI_BACKEND="$KWIN_QSG_RHI_BACKEND" \
  KWIN_QMLSCENE_DEVICE="$KWIN_QMLSCENE_DEVICE" \
  PLASMA_QT_QUICK_BACKEND="$PLASMA_QT_QUICK_BACKEND" \
  PLASMA_QSG_RHI_BACKEND="$PLASMA_QSG_RHI_BACKEND" \
  PLASMA_QMLSCENE_DEVICE="$PLASMA_QMLSCENE_DEVICE" \
  PLASMA_QT_WAYLAND_CLIENT_BUFFER_INTEGRATION="$PLASMA_QT_WAYLAND_CLIENT_BUFFER_INTEGRATION" \
  KDE_QT_QPA_PLATFORMTHEME="$KDE_QT_QPA_PLATFORMTHEME" \
  KDE_QT_STYLE_OVERRIDE="$KDE_QT_STYLE_OVERRIDE" \
  QT_QUICK_CONTROLS_STYLE="$KDE_QT_QUICK_CONTROLS_STYLE" \
  "${PLASMA_ENV[@]}" \
	  dbus-run-session -- "$XS_PREFIX/bin/bash" -lc '
	    set -u
	    printf "%s\n" "$DBUS_SESSION_BUS_ADDRESS" > "$KDE_SESSION_BUS_FILE"
	    export DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"
	    xios_export_or_unset() {
	      name="$1"; value="$2"
	      if [ -n "$value" ]; then
	        export "$name=$value"
	      else
	        unset "$name"
	      fi
	    }
	    xios_start_session_helper() {
	      b="$1"; log="$2"; name="${b##*/}"
	      [ -x "$b" ] || return 0
	      ps ax 2>/dev/null | grep -v grep | grep -q "$name" && return 0
	      "$b" >"$log" 2>&1 &
	    }
	    # Rewrites the status file to "down" if the session dies after bring-up,
	    # so a stale "up" does not linger for the Xios picker. No-op when run by
	    # hand (env unset). Only overwrites a steady state for OUR preset --
	    # a different preset/state means a newer launcher owns the file.
	    mark_session_down() {
	      why="$1"
	      f="${XIOS_SESSION_STATUS_FILE:-}"; p="${XIOS_SESSION_STATUS_PRESET:-}"
	      [ -n "$f" ] && [ -n "$p" ] && [ -f "$f" ] || return 0
	      cur_preset="$(sed -n "s/.*\"preset\":\"\([^\"]*\)\".*/\1/p" "$f" 2>/dev/null)"
	      cur_state="$(sed -n "s/.*\"state\":\"\([^\"]*\)\".*/\1/p" "$f" 2>/dev/null)"
	      [ "$cur_preset" = "$p" ] || return 0
	      case "$cur_state" in up|compositor-only|waiting) ;; *) return 0 ;; esac
	      printf "{\"preset\":\"%s\",\"state\":\"down\",\"message\":\"%s\",\"at\":\"%s\"}\n" \
	        "$p" "$why" "$(date "+%Y-%m-%dT%H:%M:%S")" >"$f" 2>/dev/null || true
	    }
	    export XIOS_HWBRIDGE_BUS="${XIOS_HWBRIDGE_BUS:-session}"
	    xios_start_session_helper "$LIBEXEC/xios-hwbridged" "$XDG_RUNTIME_DIR/xios-hwbridged.log"
	    xios_start_session_helper "$LIBEXEC/xios-sensord" "$XDG_RUNTIME_DIR/xios-sensord.log"
	    xios_start_session_helper "$LIBEXEC/xios-sysintd" "$XDG_RUNTIME_DIR/xios-sysintd.log"
    kded_pid=
    if [ -x "$KDED_BIN" ] && [ "${XIOS_KDE_START_KDED:-1}" != 0 ]; then
      echo "launch kded: $KDED_BIN --replace"
      (
        export QT_QPA_PLATFORM="${KDED_QT_QPA_PLATFORM:-offscreen}"
        export QT_QUICK_BACKEND=software
        unset QSG_RHI_BACKEND QMLSCENE_DEVICE
        unset WAYLAND_DISPLAY
        "$KDED_BIN" --replace >"$KDED_LOG" 2>&1
      ) &
      kded_pid=$!
      sleep "${KDED_STARTUP_GRACE:-0.5}"
    fi
    xios_export_or_unset QT_QUICK_BACKEND "$KWIN_QT_QUICK_BACKEND"
    xios_export_or_unset QSG_RHI_BACKEND "$KWIN_QSG_RHI_BACKEND"
    xios_export_or_unset QMLSCENE_DEVICE "$KWIN_QMLSCENE_DEVICE"
    xios_export_or_unset QT_QPA_PLATFORMTHEME "$KDE_QT_QPA_PLATFORMTHEME"
    xios_export_or_unset QT_STYLE_OVERRIDE "$KDE_QT_STYLE_OVERRIDE"
    unset QT_WAYLAND_CLIENT_BUFFER_INTEGRATION
	    echo "launch kwin: QT_QUICK_BACKEND=${QT_QUICK_BACKEND-<unset>} QSG_RHI_BACKEND=${QSG_RHI_BACKEND-<unset>}"
	    # Auto keyboard. KWin owns the text-input state (the iosc-side one is always
	    # empty in the nested case), and it filters zwp_input_method_v1 to the child
	    # IT launches, so ios-inputd has to come up this way rather than beside us.
	    # It then registers on the iosc input socket as the input-method proxy:
	    # traits out to the Xios app, typed text back in. See osk-plan.md.
	    # NOTE: this whole block lives inside a single-quoted bash -lc string,
	    # so no apostrophes here.
	    kwin_im_args=""
	    kwin_im_cmd="$IOS_INPUTD_BIN --proxy -s $IOSC_INPUT_SOCK"
	    if [ -x "$IOS_INPUTD_BIN" ] && [ "${KDE_AUTO_KEYBOARD:-1}" = 1 ]; then
	      kwin_im_args="--inputmethod"
	      # KWin watches kwinrc [Wayland] InputMethod and calls setInputMethodCommand
	      # with whatever it finds. An empty value there STOPS the input method and
	      # destroys the connection that is allowed to bind zwp_input_method_v1,
	      # which races the child we just launched and silently disables the auto
	      # keyboard. Publishing the identical command in kwinrc makes that callback
	      # a no-op (setInputMethodCommand returns early on an unchanged command).
	      im_desktop="$XDG_DATA_DIRS/applications/ios-inputd.desktop"
	      mkdir -p "$(dirname "$im_desktop")" 2>/dev/null || true
	      # Double quotes, not single: this block is inside a single-quoted bash -lc
	      # string, so a nested single quote closes it and the \n stops being an
	      # escape. bash -n does not catch that; the file just comes out on one line.
	      printf "%s\n" "[Desktop Entry]" "Type=Application" "Name=Xios iOS keyboard bridge" \
	        "Exec=$kwin_im_cmd" "NoDisplay=true" "X-KDE-Wayland-VirtualKeyboard=true" \
	        > "$im_desktop" 2>/dev/null || true
	      kwriteconfig6 --file kwinrc --group Wayland --key InputMethod "$im_desktop" 2>/dev/null || true
	      kwriteconfig6 --file kwinrc --group Wayland --key VirtualKeyboardEnabled true 2>/dev/null || true
	      echo "launch kwin: input method $kwin_im_cmd"
	    elif [ "${KDE_AUTO_KEYBOARD:-1}" = 1 ]; then
	      echo "launch kwin: no ios-inputd at $IOS_INPUTD_BIN; iOS keyboard will not auto-pop"
	    fi
	    "$KWIN_BIN" --wayland-display "$WAYLAND_DISPLAY" --socket "$KWIN_SOCKET" \
	      --width "$KWIN_W" --height "$KWIN_H" --no-global-shortcuts \
	      ${kwin_im_args:+$kwin_im_args "$kwin_im_cmd"} &
    kwin_pid=$!
    for _ in $(seq 1 60); do
      [ -S "$XDG_RUNTIME_DIR/$KWIN_SOCKET" ] && break
      kill -0 "$kwin_pid" 2>/dev/null || break
      sleep 0.2
    done
    if [ ! -S "$XDG_RUNTIME_DIR/$KWIN_SOCKET" ]; then
      echo "kwin socket did not appear: $XDG_RUNTIME_DIR/$KWIN_SOCKET"
      wait "$kwin_pid"
      [ -z "$kded_pid" ] || kill "$kded_pid" 2>/dev/null || true
      exit 1
    fi
    kamd_pid=
    if [ -x "$KAMD_BIN" ] && [ "${XIOS_KDE_START_KAMD:-1}" != 0 ]; then
      # The activity service has no windows. Keep it off the Wayland/EGL path
      # instead of allocating a software QtQuick backend it never displays.
      (
        export QT_QPA_PLATFORM="${KAMD_QT_QPA_PLATFORM:-offscreen}"
        export QT_QUICK_BACKEND=software
        unset QSG_RHI_BACKEND QMLSCENE_DEVICE
        unset WAYLAND_DISPLAY QT_WAYLAND_CLIENT_BUFFER_INTEGRATION
        "$KAMD_BIN"
      ) &
      kamd_pid=$!
      sleep 0.5
    fi
    # PowerDevil is a standalone daemon (not a kded module) -- must be started
    # explicitly. Battery/AC comes over DBus from the xios-hwbridged UPower
    # interface; brightness via the KWin DBus interface. No suspend/hibernate
    # (no logind). Set XIOS_KDE_START_POWERDEVIL=0 to skip.
    # NB: no apostrophes here -- this block is inside a single-quoted bash -lc.
    powerdevil_pid=
    if [ -x "$POWERDEVIL_BIN" ] && [ "${XIOS_KDE_START_POWERDEVIL:-1}" != 0 ]; then
      (
        export QT_QPA_PLATFORM="${POWERDEVIL_QT_QPA_PLATFORM:-offscreen}"
        export QT_QUICK_BACKEND=software
        unset QSG_RHI_BACKEND QMLSCENE_DEVICE
        unset WAYLAND_DISPLAY QT_WAYLAND_CLIENT_BUFFER_INTEGRATION
        "$POWERDEVIL_BIN"
      ) >>"$KDE_LOG" 2>&1 &
      powerdevil_pid=$!
      echo "launch powerdevil: $POWERDEVIL_BIN"
    fi
    export WAYLAND_DISPLAY="$KWIN_SOCKET"
    xios_export_or_unset QT_QUICK_BACKEND "$PLASMA_QT_QUICK_BACKEND"
    xios_export_or_unset QSG_RHI_BACKEND "$PLASMA_QSG_RHI_BACKEND"
    xios_export_or_unset QMLSCENE_DEVICE "$PLASMA_QMLSCENE_DEVICE"
    xios_export_or_unset QT_QPA_PLATFORMTHEME "$KDE_QT_QPA_PLATFORMTHEME"
    xios_export_or_unset QT_STYLE_OVERRIDE "$KDE_QT_STYLE_OVERRIDE"
    xios_export_or_unset QT_WAYLAND_CLIENT_BUFFER_INTEGRATION "$PLASMA_QT_WAYLAND_CLIENT_BUFFER_INTEGRATION"
    plasma_args=()
    if [ -n "${PLASMA_SHELL_PLUGIN:-}" ]; then
      plasma_args+=(--shell-plugin "$PLASMA_SHELL_PLUGIN")
    fi
    if [ "${PLASMA_NO_RESPAWN:-1}" != 0 ]; then
      plasma_args+=(--no-respawn)
    fi
    echo "launch plasmashell: $PLASMA_BIN ${plasma_args[*]}"
    echo "plasma render env: QT_QUICK_BACKEND=${QT_QUICK_BACKEND-<unset>} QSG_RHI_BACKEND=${QSG_RHI_BACKEND-<unset>} QT_WAYLAND_CLIENT_BUFFER_INTEGRATION=${QT_WAYLAND_CLIENT_BUFFER_INTEGRATION-<unset>}"
    "$PLASMA_BIN" "${plasma_args[@]}" &
    plasma_pid=$!

    sleep "${PLASMA_STARTUP_GRACE:-5}"
    if ! kill -0 "$plasma_pid" 2>/dev/null; then
      wait "$plasma_pid"
      plasma_rc=$?
      echo "plasmashell exited during startup (rc=$plasma_rc); restarting once"
      "$PLASMA_BIN" "${plasma_args[@]}" &
      plasma_pid=$!
      sleep "${PLASMA_RESTART_GRACE:-3}"
      if ! kill -0 "$plasma_pid" 2>/dev/null; then
        wait "$plasma_pid"
        plasma_rc=$?
        echo "plasmashell exited after restart (rc=$plasma_rc); stopping KWin"
        kill "$kwin_pid" 2>/dev/null || true
        wait "$kwin_pid"
        [ -z "$kamd_pid" ] || kill "$kamd_pid" 2>/dev/null || true
        [ -z "$kded_pid" ] || kill "$kded_pid" 2>/dev/null || true
        mark_session_down "plasmashell exited (rc=$plasma_rc)"
        exit "$plasma_rc"
      fi
    fi

    while kill -0 "$kwin_pid" 2>/dev/null; do
      if ! kill -0 "$plasma_pid" 2>/dev/null; then
        wait "$plasma_pid"
        plasma_rc=$?
        echo "plasmashell exited (rc=$plasma_rc); stopping KWin"
        kill "$kwin_pid" 2>/dev/null || true
        wait "$kwin_pid"
        [ -z "$kamd_pid" ] || kill "$kamd_pid" 2>/dev/null || true
        [ -z "$kded_pid" ] || kill "$kded_pid" 2>/dev/null || true
        mark_session_down "plasmashell exited (rc=$plasma_rc)"
        exit "$plasma_rc"
      fi
      sleep 1
    done
    wait "$kwin_pid"
    kwin_rc=$?
    echo "kwin exited (rc=$kwin_rc); stopping plasmashell"
    kill "$plasma_pid" 2>/dev/null || true
    [ -z "$kamd_pid" ] || kill "$kamd_pid" 2>/dev/null || true
    [ -z "$kded_pid" ] || kill "$kded_pid" 2>/dev/null || true
    mark_session_down "kwin exited (rc=$kwin_rc)"
    exit "$kwin_rc"
  ' >"$KDE_LOG" 2>&1 </dev/null &
KDEPID=$!

echo "==> wait for KWin client socket"
for _ in $(seq 1 80); do
  [ -S "$KWIN_SOCK_PATH" ] && break
  kill -0 "$KDEPID" 2>/dev/null || break
  sleep 0.25
done
if [ ! -S "$KWIN_SOCK_PATH" ]; then
  echo "!! KWin did not create $KWIN_SOCK_PATH"
  sed 's/^/   /' "$KDE_LOG" 2>/dev/null | tail -80
  exit 1
fi

if [ -z "${XIOS_SESSION_SLOT:-}" ] || [ "${XIOS_SLOT_FOREGROUND:-0}" = 1 ]; then
  echo "==> foreground Xios app (shows the iosc output containing KWin/Plasma)"
  uiopen -b com.max.xios 2>/dev/null || uiopen com.max.xios 2>/dev/null || true
else
  echo "==> slot $XIOS_SESSION_SLOT: leaving Xios foreground unchanged"
fi

for _ in $(seq 1 60); do
  kde_process_running "plasmashell" && break
  sleep 0.5
done

echo "   outer wayland: $([ -S "$WSOCK" ] && echo up || echo MISSING)"
echo "   kwin socket:   $([ -S "$KWIN_SOCK_PATH" ] && echo up || echo MISSING)"
echo "   shell flavor:  $KDE_PLASMA_FLAVOR"
echo "   plasmashell:   $(kde_process_running "plasmashell" && echo running || echo not-yet)"
echo "   xios.json:     $(cat "$XIOS_JSON_PATH" 2>/dev/null)"
echo "==> logs: $IOSC_LOG and $KDE_LOG"
