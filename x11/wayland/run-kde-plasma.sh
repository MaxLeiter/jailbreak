#!/usr/bin/env bash
# run-kde-plasma.sh — first-light KDE Plasma session on iOS (ROOT).
#
# KWin's current first-light backend is nested Wayland: iosc owns the output
# IOSurface that Xios presents, then kwin_wayland runs as a QtWayland/ANGLE client
# inside iosc and exposes its own socket for Plasma clients. This script starts:
#
#   iosc output compositor -> kwin_wayland --socket kwin-ios-test -> plasmashell
#
# It is intended to be called by xios-session's "kde" preset, but can be run by
# hand on-device for diagnosis.
set -u

export PATH=/var/jb/usr/local/bin:/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:/usr/bin:/bin:$PATH
export XDG_RUNTIME_DIR=/var/jb/tmp

TMP=/var/jb/tmp
WSOCK="$XDG_RUNTIME_DIR/wayland-0"
IOSC_BIN="${IOSC_BIN:-/var/jb/usr/local/bin/iosc}"
KWIN_BIN="${KWIN_BIN:-/var/jb/Applications/KDE/kwin_wayland.app/kwin_wayland}"
PLASMA_BIN="${PLASMA_BIN:-/var/jb/Applications/KDE/plasmashell.app/plasmashell}"
KWIN_SOCKET="${KWIN_SOCKET:-kwin-ios-test}"
KWIN_SOCK_PATH="$XDG_RUNTIME_DIR/$KWIN_SOCKET"
IOSC_LOGICAL="${IOSC_LOGICAL:-1440x1080}"
KDE_KWIN_SIZE="${KDE_KWIN_SIZE:-1360x1000}"
KWIN_W="${KDE_KWIN_SIZE%x*}"
KWIN_H="${KDE_KWIN_SIZE#*x}"
ANGLE=/var/jb/lib/angle
KDE_LOG="$TMP/kde-plasma.log"
IOSC_LOG="$TMP/iosc.log"

[ -x "$IOSC_BIN" ] || { echo "!! $IOSC_BIN missing/not executable"; exit 1; }
[ -x "$KWIN_BIN" ] || { echo "!! $KWIN_BIN missing/not executable"; exit 1; }
[ -x "$PLASMA_BIN" ] || { echo "!! $PLASMA_BIN missing/not executable"; exit 1; }
case "$KWIN_W:$KWIN_H" in
  *[!0-9:]*|":"|*":") echo "!! invalid KDE_KWIN_SIZE=$KDE_KWIN_SIZE, expected WxH"; exit 2 ;;
esac

echo "==> stop prior iosc/KDE session pieces"
ps ax | grep -v grep | grep -E "Xios :| Xios$|/Xios\.app/Xios|(^|[ /])iosc( |$)|kwin_wayland|plasmashell|plasmawindowed|dbus-daemon.*--session|dbus-run-session" \
  | awk '{print $1}' | while read -r pid; do
      [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ] || kill -TERM "$pid" 2>/dev/null
  done
sleep 1
ps ax | grep -v grep | grep -E "kwin_wayland|plasmashell|plasmawindowed" \
  | awk '{print $1}' | while read -r pid; do
      [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ] || kill -9 "$pid" 2>/dev/null
  done

rm -f "$WSOCK" "$WSOCK.lock" "$KWIN_SOCK_PATH" "$KWIN_SOCK_PATH.lock" \
      "$TMP/iosc-ddx.sock" "$TMP/iosc-input.sock" "$TMP/iosc-clipboard.sock" \
      "$TMP/iosc-wm.sock" "$TMP/xios.json" "$TMP/kde-session-bus" \
      "$IOSC_LOG" "$KDE_LOG" 2>/dev/null || true

echo "==> ANGLE Linux so-name symlinks"
ln -sf libGLESv2.dylib "$ANGLE/libGLESv2.so.2" 2>/dev/null
ln -sf libGLESv2.dylib "$ANGLE/libGLESv2.so"   2>/dev/null
ln -sf libEGL.dylib    "$ANGLE/libEGL.so.1"    2>/dev/null
ln -sf libEGL.dylib    "$ANGLE/libEGL.so"      2>/dev/null

echo "==> ensure GSettings schemas are compiled"
if [ ! -e /var/jb/usr/share/glib-2.0/schemas/gschemas.compiled ]; then
  glib-compile-schemas /var/jb/usr/share/glib-2.0/schemas 2>/dev/null || true
fi

[ -r /var/jb/etc/profile.d/xios-pulse.sh ] && . /var/jb/etc/profile.d/xios-pulse.sh && xios_pulse_start

echo "==> start iosc output compositor (logical $IOSC_LOGICAL) -> $IOSC_LOG"
nohup env \
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
  IOSC_FRAME_PULSE="${IOSC_FRAME_PULSE:-1}" \
  IOSC_IGNORE_ACTIVE_SESSION=1 \
  "$IOSC_BIN" -logical "$IOSC_LOGICAL" >"$IOSC_LOG" 2>&1 </dev/null &
ICPID=$!

for _ in $(seq 1 50); do
  [ -S "$WSOCK" ] && [ -f "$TMP/xios.json" ] && break
  kill -0 "$ICPID" 2>/dev/null || break
  sleep 0.2
done
if ! kill -0 "$ICPID" 2>/dev/null; then
  echo "!! iosc died:"
  sed 's/^/   /' "$IOSC_LOG" 2>/dev/null
  exit 1
fi
[ -S "$WSOCK" ] || { echo "!! iosc did not create $WSOCK"; exit 1; }

if chown mobile:mobile "$TMP/iosc-ddx.sock" 2>/dev/null || chown 501:501 "$TMP/iosc-ddx.sock" 2>/dev/null; then
  chmod 0660 "$TMP/iosc-ddx.sock" 2>/dev/null
else
  chmod 0600 "$TMP/iosc-ddx.sock" 2>/dev/null
  echo "!! could not hand $TMP/iosc-ddx.sock to mobile; keeping it owner-only"
fi

echo "==> launch KWin + plasmashell in one session bus -> $KDE_LOG"
nohup env \
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
  WAYLAND_DISPLAY=wayland-0 \
  KWIN_BIN="$KWIN_BIN" \
  PLASMA_BIN="$PLASMA_BIN" \
  KWIN_SOCKET="$KWIN_SOCKET" \
  KWIN_W="$KWIN_W" \
  KWIN_H="$KWIN_H" \
  DYLD_LIBRARY_PATH="/var/jb/usr/lib:/var/jb/lib/angle" \
  XDG_DATA_DIRS=/var/jb/usr/share \
  XDG_CONFIG_DIRS=/var/jb/etc/xdg:/var/jb/usr/etc/xdg \
  GSETTINGS_SCHEMA_DIR=/var/jb/usr/share/glib-2.0/schemas \
  HOME=/var/jb/var/root \
  KDE_FULL_SESSION=true \
  KDE_SESSION_VERSION=6 \
  XDG_CURRENT_DESKTOP=KDE \
  XDG_SESSION_TYPE=wayland \
  QT_QPA_PLATFORM=wayland \
  QT_PLUGIN_PATH=/var/jb/usr/lib/qt6/plugins \
  QML2_IMPORT_PATH=/var/jb/usr/lib/qt6/qml \
  QML_IMPORT_PATH=/var/jb/usr/lib/qt6/qml \
  QT_QUICK_CONTROLS_STYLE=org.kde.desktop \
  dbus-run-session -- /var/jb/usr/bin/bash -lc '
    set -u
    printf "%s\n" "$DBUS_SESSION_BUS_ADDRESS" > /var/jb/tmp/kde-session-bus
    export DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"
    export WAYLAND_DISPLAY=wayland-0
    "$KWIN_BIN" --wayland-display wayland-0 --socket "$KWIN_SOCKET" \
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
    export WAYLAND_DISPLAY="$KWIN_SOCKET"
    "$PLASMA_BIN" &
    plasma_pid=$!
    wait "$kwin_pid"
    kill "$plasma_pid" 2>/dev/null || true
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

for _ in $(seq 1 20); do
  pgrep -f "plasmashell" >/dev/null 2>&1 && break
  sleep 0.5
done

echo "   outer wayland: $([ -S "$WSOCK" ] && echo up || echo MISSING)"
echo "   kwin socket:   $([ -S "$KWIN_SOCK_PATH" ] && echo up || echo MISSING)"
echo "   plasmashell:   $(pgrep -f "plasmashell" >/dev/null 2>&1 && echo running || echo not-yet)"
echo "   xios.json:     $(cat "$TMP/xios.json" 2>/dev/null)"
echo "==> logs: $IOSC_LOG and $KDE_LOG"
