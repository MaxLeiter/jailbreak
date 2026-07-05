#!/usr/bin/env bash
# run-kde-plasma.sh — first-light KDE Plasma session on iOS (ROOT).
#
# KWin's current first-light backend is nested Wayland: iosc owns the output
# IOSurface that Xios presents, then kwin_wayland runs as a QtWayland/ANGLE client
# inside iosc and exposes its own socket for Plasma clients. This script starts:
#
#   iosc output compositor -> kwin_wayland --socket kwin-ios-test -> plasmashell
#
# It is intended to be called by xios-session's KDE presets, but can be run by
# hand on-device for diagnosis. Set KDE_PLASMA_FLAVOR=desktop|nano|mobile, or
# pass the flavor as the first argument.
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
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$XS_TMP}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"

TMP="$XDG_RUNTIME_DIR"
WSOCK="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
IOSC_BIN="${IOSC_BIN:-$XS_PREFIX/local/bin/iosc}"
KWIN_BIN="${KWIN_BIN:-$(jb_path /Applications/KDE/kwin_wayland.app/kwin_wayland)}"
PLASMA_BIN="${PLASMA_BIN:-$(jb_path /Applications/KDE/plasmashell.app/plasmashell)}"
KAMD_BIN="${KAMD_BIN:-$XS_PREFIX/libexec/kactivitymanagerd}"
KWIN_SOCKET="${KWIN_SOCKET:-kwin-ios-test}"
KWIN_SOCK_PATH="$XDG_RUNTIME_DIR/$KWIN_SOCKET"
KDE_SESSION_BUS_FILE="$TMP/kde-session-bus${XIOS_SESSION_SLOT:+-$XIOS_SESSION_SLOT}"
IOSC_LOGICAL="${IOSC_LOGICAL:-1440x1080}"
XIOS_JSON_PATH="${XIOS_JSON_PATH:-$TMP/xios.json}"
IOSC_DDX_SOCK="${IOSC_DDX_SOCK:-$TMP/iosc-ddx.sock}"
IOSC_INPUT_SOCK="${IOSC_INPUT_SOCK:-$TMP/iosc-input.sock}"
IOSC_CLIPBOARD_SOCK="${IOSC_CLIPBOARD_SOCK:-$TMP/iosc-clipboard.sock}"
IOSC_WM_SOCK="${IOSC_WM_SOCK:-$TMP/iosc-wm.sock}"
KDE_KWIN_SIZE="${KDE_KWIN_SIZE:-1360x1000}"
KWIN_W="${KDE_KWIN_SIZE%x*}"
KWIN_H="${KDE_KWIN_SIZE#*x}"
KDE_PLASMA_FLAVOR="${KDE_PLASMA_FLAVOR:-${1:-desktop}}"
ANGLE="${ANGLE:-$(jb_path /lib/angle)}"
KDE_LOG="${KDE_LOG:-$TMP/kde-plasma.log}"
IOSC_LOG="${IOSC_LOG:-$TMP/iosc.log}"
KWIN_QT_QUICK_BACKEND="${KWIN_QT_QUICK_BACKEND:-${QT_QUICK_BACKEND:-software}}"
KWIN_QSG_RHI_BACKEND="${KWIN_QSG_RHI_BACKEND:-${QSG_RHI_BACKEND:-software}}"
KWIN_QMLSCENE_DEVICE="${KWIN_QMLSCENE_DEVICE:-${QMLSCENE_DEVICE:-softwarecontext}}"
PLASMA_QT_QUICK_BACKEND="${PLASMA_QT_QUICK_BACKEND-${QT_QUICK_BACKEND-}}"
PLASMA_QSG_RHI_BACKEND="${PLASMA_QSG_RHI_BACKEND:-${QSG_RHI_BACKEND:-opengl}}"
PLASMA_QMLSCENE_DEVICE="${PLASMA_QMLSCENE_DEVICE-${QMLSCENE_DEVICE-}}"
PLASMA_QT_WAYLAND_CLIENT_BUFFER_INTEGRATION="${PLASMA_QT_WAYLAND_CLIENT_BUFFER_INTEGRATION:-${QT_WAYLAND_CLIENT_BUFFER_INTEGRATION:-wayland-egl}}"

PLASMA_ENV=()
KDE_PLASMA_LABEL="KDE Plasma"
KDE_QT_QUICK_CONTROLS_STYLE="${KDE_QT_QUICK_CONTROLS_STYLE:-org.kde.desktop}"
case "$KDE_PLASMA_FLAVOR" in
  desktop|plasma|kde)
    KDE_PLASMA_FLAVOR=desktop
    KDE_PLASMA_LABEL="KDE Plasma (Xios first light)"
    PLASMA_SHELL_PLUGIN="${PLASMA_SHELL_PLUGIN:-org.kde.plasma.xios}"
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

[ -x "$IOSC_BIN" ] || { echo "!! $IOSC_BIN missing/not executable"; exit 1; }
[ -x "$KWIN_BIN" ] || { echo "!! $KWIN_BIN missing/not executable"; exit 1; }
[ -x "$PLASMA_BIN" ] || { echo "!! $PLASMA_BIN missing/not executable"; exit 1; }
case "$KWIN_W:$KWIN_H" in
  *[!0-9:]*|":"|*":") echo "!! invalid KDE_KWIN_SIZE=$KDE_KWIN_SIZE, expected WxH"; exit 2 ;;
esac

kde_process_running() {
  ps ax | grep -v grep | grep -E "$1" >/dev/null 2>&1
}

if [ -z "${XIOS_SESSION_SLOT:-}" ]; then
  echo "==> stop prior iosc/KDE session pieces"
  ps ax | grep -v grep | grep -E "Xios :| Xios$|/Xios\.app/Xios|(^|[ /])iosc( |$)|kwin_wayland|plasmashell|plasmawindowed|kactivitymanagerd|dbus-daemon.*--session|dbus-run-session" \
    | awk '{print $1}' | while read -r pid; do
        [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ] || kill -TERM "$pid" 2>/dev/null
    done
  sleep 1
  ps ax | grep -v grep | grep -E "kwin_wayland|plasmashell|plasmawindowed" \
    | awk '{print $1}' | while read -r pid; do
        [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ] || kill -9 "$pid" 2>/dev/null
    done
fi

rm -f "$WSOCK" "$WSOCK.lock" "$KWIN_SOCK_PATH" "$KWIN_SOCK_PATH.lock" \
      "$IOSC_DDX_SOCK" "$IOSC_INPUT_SOCK" "$IOSC_CLIPBOARD_SOCK" \
      "$IOSC_WM_SOCK" "$XIOS_JSON_PATH" "$KDE_SESSION_BUS_FILE" \
      "$IOSC_LOG" "$KDE_LOG" 2>/dev/null || true

echo "==> ANGLE Linux so-name symlinks"
ln -sf libGLESv2.dylib "$ANGLE/libGLESv2.so.2" 2>/dev/null
ln -sf libGLESv2.dylib "$ANGLE/libGLESv2.so"   2>/dev/null
ln -sf libEGL.dylib    "$ANGLE/libEGL.so.1"    2>/dev/null
ln -sf libEGL.dylib    "$ANGLE/libEGL.so"      2>/dev/null

echo "==> ensure GSettings schemas are compiled"
if [ ! -e "$XS_PREFIX/share/glib-2.0/schemas/gschemas.compiled" ]; then
  glib-compile-schemas "$XS_PREFIX/share/glib-2.0/schemas" 2>/dev/null || true
fi

kde_app_support_link() {
  local name="$1"
  local target="$XS_PREFIX/share/$name"
  local link="$XS_VAR/root/Library/Application Support/$name"
  [ -e "$target" ] || return 0
  mkdir -p "$XS_VAR/root/Library/Application Support"
  if [ -L "$link" ]; then
    ln -sfn "$target" "$link" 2>/dev/null || true
  elif [ ! -e "$link" ]; then
    ln -s "$target" "$link" 2>/dev/null || true
  else
    echo "!! $link already exists; leaving it in place"
  fi
}

if [ "${XIOS_KDE_APP_SUPPORT_BRIDGE:-1}" != 0 ]; then
  echo "==> bridge Qt/KPackage Darwin app-data paths to $XS_PREFIX/share"
  for name in plasma icons applications metainfo mime kservices6 knotifications6 kglobalaccel kpackage dbus-1 krunner qlogging-categories6; do
    kde_app_support_link "$name"
  done
fi

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
"$SETSID" env \
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
  IOSC_FRAME_PULSE="${IOSC_FRAME_PULSE:-1}" \
  IOSC_IGNORE_ACTIVE_SESSION=1 \
  "$IOSC_BIN" -logical "$IOSC_LOGICAL" -s "$WAYLAND_DISPLAY" \
    -ddx-sock "$IOSC_DDX_SOCK" -json "$XIOS_JSON_PATH" \
    -input-sock "$IOSC_INPUT_SOCK" -clipboard-sock "$IOSC_CLIPBOARD_SOCK" \
    -wm-sock "$IOSC_WM_SOCK" >"$IOSC_LOG" 2>&1 </dev/null &
ICPID=$!

for _ in $(seq 1 50); do
  [ -S "$WSOCK" ] && [ -f "$XIOS_JSON_PATH" ] && break
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

echo "==> launch KWin + plasmashell ($KDE_PLASMA_LABEL) in one session bus -> $KDE_LOG"
"$SETSID" env \
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
  WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
  KWIN_BIN="$KWIN_BIN" \
  PLASMA_BIN="$PLASMA_BIN" \
  KAMD_BIN="$KAMD_BIN" \
  KWIN_SOCKET="$KWIN_SOCKET" \
  KWIN_W="$KWIN_W" \
  KWIN_H="$KWIN_H" \
  KDE_SESSION_BUS_FILE="$KDE_SESSION_BUS_FILE" \
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
    xios_export_or_unset QT_QUICK_BACKEND "$KWIN_QT_QUICK_BACKEND"
    xios_export_or_unset QSG_RHI_BACKEND "$KWIN_QSG_RHI_BACKEND"
    xios_export_or_unset QMLSCENE_DEVICE "$KWIN_QMLSCENE_DEVICE"
    unset QT_WAYLAND_CLIENT_BUFFER_INTEGRATION
    echo "launch kwin: QT_QUICK_BACKEND=${QT_QUICK_BACKEND-<unset>} QSG_RHI_BACKEND=${QSG_RHI_BACKEND-<unset>}"
    "$KWIN_BIN" --wayland-display "$WAYLAND_DISPLAY" --socket "$KWIN_SOCKET" \
      --width "$KWIN_W" --height "$KWIN_H" --no-global-shortcuts &
    kwin_pid=$!
    for _ in $(seq 1 60); do
      [ -S "$XDG_RUNTIME_DIR/$KWIN_SOCKET" ] && break
      kill -0 "$kwin_pid" 2>/dev/null || break
      sleep 0.2
    done
    if [ ! -S "$XDG_RUNTIME_DIR/$KWIN_SOCKET" ]; then
      echo "kwin socket did not appear: $XDG_RUNTIME_DIR/$KWIN_SOCKET"
      wait "$kwin_pid"
      exit 1
    fi
    kamd_pid=
    if [ -x "$KAMD_BIN" ] && [ "${XIOS_KDE_START_KAMD:-1}" != 0 ]; then
      "$KAMD_BIN" &
      kamd_pid=$!
      sleep 0.5
    fi
    export WAYLAND_DISPLAY="$KWIN_SOCKET"
    xios_export_or_unset QT_QUICK_BACKEND "$PLASMA_QT_QUICK_BACKEND"
    xios_export_or_unset QSG_RHI_BACKEND "$PLASMA_QSG_RHI_BACKEND"
    xios_export_or_unset QMLSCENE_DEVICE "$PLASMA_QMLSCENE_DEVICE"
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
        exit "$plasma_rc"
      fi
      sleep 1
    done
    wait "$kwin_pid"
    kwin_rc=$?
    echo "kwin exited (rc=$kwin_rc); stopping plasmashell"
    kill "$plasma_pid" 2>/dev/null || true
    [ -z "$kamd_pid" ] || kill "$kamd_pid" 2>/dev/null || true
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

echo "==> foreground Xios app (shows the iosc output containing KWin/Plasma)"
uiopen -b com.max.xios 2>/dev/null || uiopen com.max.xios 2>/dev/null || true

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
