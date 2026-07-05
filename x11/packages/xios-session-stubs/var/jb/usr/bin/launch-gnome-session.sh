#!/bin/sh
# launch-gnome-session.sh — bring up GNOME through gnome-session on Xios.
#
# This is the packaged GNOME path used by xios-session. It prepares the
# Shell/Mutter iOS environment and lets gnome-session own org.gnome.Shell
# instead of execing gnome-shell directly.
set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
if [ -z "${XS_JB+x}" ]; then
  case "$SCRIPT_DIR/" in
    /var/jb/*) XS_JB=/var/jb ;;
    *)         XS_JB= ;;
  esac
fi
XS_SUBPREFIX="${XS_SUBPREFIX:-/usr}"
if [ -n "${XS_JB:-}" ]; then
  XS_TMP="${XS_TMP:-$XS_JB/tmp}"
  XS_VAR="${XS_VAR:-$XS_JB/var}"
else
  XS_TMP="${XS_TMP:-${XIOS_RUNTIME_TMP:-/var/tmp}}"
  XS_VAR="${XS_VAR:-${XIOS_RUNTIME_VAR:-/var}}"
fi
PREFIX="${XS_PREFIX:-$XS_JB$XS_SUBPREFIX}"
[ -n "$PREFIX" ] || PREFIX=/usr
LIBEXEC="${LIBEXEC:-$PREFIX/libexec}"
SHELL_BIN="${SHELL_BIN:-$PREFIX/bin/gnome-shell}"
SHELL_LIB="${SHELL_LIB:-$PREFIX/lib/gnome-shell}"
PLUGINS="${PLUGINS:-$PREFIX/lib/mutter-14/plugins}"
SYSTEM_XDG_CONFIG="${XS_JB:-}/etc/xdg"
if [ -z "${ANGLE+x}" ]; then
  if [ -n "${XS_JB:-}" ]; then ANGLE="$XS_JB/lib/angle"; else ANGLE=/lib/angle; fi
fi

export PATH="$PREFIX/local/bin:$PREFIX/bin:$PREFIX/sbin${XS_JB:+:$XS_JB/bin:$XS_JB/sbin}:/usr/bin:/bin:$PATH"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$XS_TMP}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export HOME="${HOME:-$XS_VAR/root}"
unset DISPLAY

slot_suffix="${XIOS_SESSION_SLOT:+-$XIOS_SESSION_SLOT}"
if [ -n "${XIOS_SESSION_SLOT:-}" ]; then
  XIOS_JSON_PATH="${XIOS_JSON_PATH:-$XS_TMP/xios-$XIOS_SESSION_SLOT.json}"
  XIOS_DDX_SOCKET="${XIOS_DDX_SOCKET:-$XS_TMP/mutter-$XIOS_SESSION_SLOT-ddx.sock}"
  XIOS_INPUT_SOCKET="${XIOS_INPUT_SOCKET:-$XS_TMP/mutter-$XIOS_SESSION_SLOT-input.sock}"
else
  XIOS_JSON_PATH="${XIOS_JSON_PATH:-$XS_TMP/xios.json}"
  XIOS_DDX_SOCKET="${XIOS_DDX_SOCKET:-$XS_TMP/mutter-ddx.sock}"
  XIOS_INPUT_SOCKET="${XIOS_INPUT_SOCKET:-$XS_TMP/mutter-input.sock}"
fi
GNOME_SHELL_LOG="${GNOME_SHELL_LOG:-$XS_TMP/gnome-shell$slot_suffix.log}"
GNOME_SESSION_BUS_FILE="${GNOME_SESSION_BUS_FILE:-$XS_TMP/gnome-session-bus$slot_suffix}"
WSOCK="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"

[ -x "$SHELL_BIN" ] || { echo "!! $SHELL_BIN missing — install the gnome-shell deb"; exit 1; }
mkdir -p "$XDG_RUNTIME_DIR" "$HOME" 2>/dev/null || true

echo "==> re-sign gnome-shell with the iosc-gl GPU union entitlement"
ENT="$XS_TMP/iosc-gl-ent.xml"
if [ -n "${XS_JB:-}" ]; then
  ENT_PATHS="<string>$XS_JB/</string><string>/tmp/</string><string>/var/</string><string>/private/var/</string>"
else
  ENT_PATHS="<string>/usr/</string><string>/tmp/</string><string>/var/</string><string>/private/var/</string>"
fi
cat > "$ENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>platform-application</key><true/>
    <key>com.apple.private.amfi.can-allow-non-platform</key><true/>
    <key>com.apple.private.skip-library-validation</key><true/>
    <key>dynamic-codesigning</key><true/>
    <key>task_for_pid-allow</key><true/>
    <key>com.apple.system-task-ports</key><true/>
    <key>com.apple.security.iokit-user-client-class</key>
    <array>
        <string>AGXDeviceUserClient</string>
        <string>IOGPUDeviceUserClient</string>
        <string>IOSurfaceRootUserClient</string>
        <string>IOSurfaceSendRight</string>
        <string>IOSurfaceAcceleratorClient</string>
    </array>
    <key>com.apple.security.exception.files.absolute-path.read-write</key>
    <array>$ENT_PATHS</array>
</dict>
</plist>
PLIST
ldid -S"$ENT" "$SHELL_BIN" && echo "   signed: $SHELL_BIN"
ldid -e "$SHELL_BIN" 2>/dev/null | grep -q AGXDeviceUserClient || {
  echo "!! entitlements did not stick — abort"
  exit 1
}

rm -f "$WSOCK" "$WSOCK.lock" "$XIOS_DDX_SOCKET" "$XIOS_JSON_PATH" \
      "$XIOS_INPUT_SOCKET" "$XS_TMP/xios-input.sock" "$GNOME_SHELL_LOG" \
      "$GNOME_SESSION_BUS_FILE" 2>/dev/null

echo "==> ANGLE + mutter-plugin so-name symlinks"
if [ -d "$ANGLE" ]; then
  ln -sf libGLESv2.dylib "$ANGLE/libGLESv2.so.2" 2>/dev/null
  ln -sf libGLESv2.dylib "$ANGLE/libGLESv2.so" 2>/dev/null
  ln -sf libEGL.dylib "$ANGLE/libEGL.so.1" 2>/dev/null
  ln -sf libEGL.dylib "$ANGLE/libEGL.so" 2>/dev/null
fi
for f in "$PLUGINS"/*.dylib; do
  [ -e "$f" ] && ln -sf "$(basename "$f")" "${f%.dylib}.so" 2>/dev/null
done

echo "==> ensure GSettings schemas compiled"
[ -d "$PREFIX/share/glib-2.0/schemas" ] && \
  glib-compile-schemas "$PREFIX/share/glib-2.0/schemas" 2>/dev/null || true

CFG="$XDG_RUNTIME_DIR/xios-gnome-session$slot_suffix"
rm -rf "$CFG" 2>/dev/null || true
mkdir -p "$CFG/config/gnome-session/sessions" "$CFG/data/applications" "$CFG/bin"
SHELL_WRAPPER="$CFG/bin/xios-gnome-shell-session"
cat > "$SHELL_WRAPPER" <<EOF
#!/bin/sh
exec "$SHELL_BIN" --wayland --wayland-display "\${WAYLAND_DISPLAY:-wayland-0}"
EOF
chmod 0755 "$SHELL_WRAPPER"
cat > "$CFG/data/applications/org.gnome.Shell.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=GNOME Shell
Exec=$SHELL_WRAPPER
NoDisplay=true
X-GNOME-Autostart-Phase=WindowManager
EOF
cat > "$CFG/config/gnome-session/sessions/xios.session" <<EOF
[GNOME Session]
Name=Xios GNOME
RequiredComponents=org.gnome.Shell;
EOF

SETSID="$(command -v setsid || true)"
if [ -z "$SETSID" ]; then
  SETSID="$XS_TMP/xsetsid"
  cat > "$SETSID" <<PYEOF
#!$PREFIX/bin/python3
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

[ -e "$PREFIX/share/zoneinfo" ] || ln -sf /var/db/timezone/zoneinfo "$PREFIX/share/zoneinfo" 2>/dev/null
XIOS_TZ="$(readlink /var/db/timezone/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')"
[ -n "$XIOS_TZ" ] && echo "==> timezone: $XIOS_TZ"

echo "==> start GNOME session -> $GNOME_SHELL_LOG"
"$SETSID" env \
  ${XIOS_TZ:+TZ="$XIOS_TZ"} \
  PATH="$PATH" HOME="$HOME" \
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
  XDG_CONFIG_HOME="$CFG/config-home" \
  XDG_CONFIG_DIRS="$CFG/config:$SYSTEM_XDG_CONFIG" \
  XDG_DATA_HOME="$CFG/data" \
  XDG_DATA_DIRS="$PREFIX/share:$PREFIX/local/share" \
  GSETTINGS_SCHEMA_DIR="$PREFIX/share/glib-2.0/schemas" \
  WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
  XIOS_DDX_SOCKET="$XIOS_DDX_SOCKET" \
  XIOS_JSON_PATH="$XIOS_JSON_PATH" \
  XIOS_INPUT_SOCKET="$XIOS_INPUT_SOCKET" \
  DYLD_LIBRARY_PATH="$PREFIX/lib:$SHELL_LIB:$PREFIX/lib/mutter-14:$ANGLE" \
  XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME XDG_SESSION_CLASS=user \
  GDK_BACKEND=wayland CLUTTER_BACKEND=wayland \
  LANG="${LANG:-C}" \
  LC_CTYPE="${LC_CTYPE:-${LANG:-C}}" \
  LIBEXEC="$LIBEXEC" \
  GNOME_SESSION_BUS_FILE="$GNOME_SESSION_BUS_FILE" \
  PULSE_PROFILE="$PREFIX/etc/profile.d/xios-pulse.sh" \
  SYSINT_LOG="$XS_TMP/xios-sysintd$slot_suffix.log" \
  dbus-run-session -- sh -c '
    export DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"
    printf %s "$DBUS_SESSION_BUS_ADDRESS" > "$GNOME_SESSION_BUS_FILE"
    [ -x "$LIBEXEC/xios-login1-stub" ] && "$LIBEXEC/xios-login1-stub" &
    [ -x "$LIBEXEC/xios-polkit-stub" ] && "$LIBEXEC/xios-polkit-stub" &
    [ -x "$LIBEXEC/xios-accounts-stub" ] && "$LIBEXEC/xios-accounts-stub" &
    [ -x "$LIBEXEC/xios-bluez-stub" ] && "$LIBEXEC/xios-bluez-stub" &
    [ -x "$LIBEXEC/xios-hwbridged" ] && "$LIBEXEC/xios-hwbridged" &
    [ -x "$LIBEXEC/xios-sensord" ] && "$LIBEXEC/xios-sensord" &
    [ -r "$PULSE_PROFILE" ] && . "$PULSE_PROFILE" && xios_pulse_start
    [ -x "$LIBEXEC/xios-sysintd" ] && "$LIBEXEC/xios-sysintd" >"$SYSINT_LOG" 2>&1 &
    sleep 1
    exec gnome-session --builtin --session=xios
  ' >"$GNOME_SHELL_LOG" 2>&1 </dev/null &
GPID=$!

session_alive() {
  kill -0 "$GPID" 2>/dev/null && return 0
  ps ax 2>/dev/null | grep -v grep | grep -E "gnome-session.*--session=xios|/usr/bin/gnome-shell" >/dev/null 2>&1
}

echo "==> wait for GNOME Shell to create the output IOSurface + rendezvous sockets"
i=0
while [ "$i" -lt 100 ]; do
  [ -f "$XIOS_JSON_PATH" ] && [ -S "$XIOS_DDX_SOCKET" ] && break
  session_alive || break
  sleep 0.2
  i=$((i + 1))
done
if ! session_alive; then
  echo "!! GNOME session died:"
  sed 's/^/   /' "$GNOME_SHELL_LOG" 2>/dev/null
  exit 1
fi
echo "   xios.json:       $(cat "$XIOS_JSON_PATH" 2>/dev/null)"
echo "   mutter-ddx.sock: $([ -S "$XIOS_DDX_SOCKET" ] && echo up || echo MISSING)"
echo "   wayland socket:  $(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | tr '\n' ' ')"

if [ -S "$XIOS_DDX_SOCKET" ]; then
  if chown mobile:mobile "$XIOS_DDX_SOCKET" 2>/dev/null || chown 501:501 "$XIOS_DDX_SOCKET" 2>/dev/null; then
    chmod 0660 "$XIOS_DDX_SOCKET" 2>/dev/null
  else
    chmod 0600 "$XIOS_DDX_SOCKET" 2>/dev/null
    echo "!! could not hand $XIOS_DDX_SOCKET to mobile; keeping it owner-only"
  fi
fi

echo "==> relaunch the Xios app"
uiopen -b com.max.xios 2>/dev/null || true
sleep 1

echo "==> GNOME session log tail:"
tail -80 "$GNOME_SHELL_LOG" 2>/dev/null | sed 's/^/   /'
echo "==> GNOME session still running: $(session_alive && echo yes || echo NO)"
