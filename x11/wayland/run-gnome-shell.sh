#!/usr/bin/env bash
# run-gnome-shell.sh — boot the real GNOME Shell on-device, in place of the mutter smoke (ROOT).
#
# ARCHITECTURE (read this first): gnome-shell is NOT a Wayland client of mutter. In modern GNOME
# the shell IS Mutter — gnome-shell links libmutter-14 and, with --wayland, brings up its OWN
# compositor via the SAME MetaBackendIOS backend the `mutter` smoke uses (backend lives in the
# libmutter-14 dylib, selected on the Wayland branch). So gnome-shell REPLACES the standalone
# `mutter --wayland`: same libmutter, same output IOSurface, same Xios rendezvous
# (/var/jb/tmp/xios.json + mutter-ddx.sock). We stop the smoke, start gnome-shell in its place,
# relaunch the Xios app. This mirrors run-mutter.sh exactly, swapping `mutter --wayland` for
# `gnome-shell` and adding the session D-Bus stubs.
#
#   ssh root@ipad 'bash -s' < run-gnome-shell.sh
#
# HARD PREREQS (see the boot runbook / docs/gnome-shell-boot-install-set.md):
#   1. The 66-deb boot set installed IN ORDER (install-gnome-boot.sh). CRITICAL: the on-device
#      libmutter-14.dylib must be the LIVE build (the one presenting now) — gnome-shell links it.
#      If the boot set would DOWNGRADE it, install everything EXCEPT libmutter-14-0.
#   2. The 8 -dev debs installed + gtk4-gpu's on-device gir batch RUN — gnome-shell statically
#      gi-imports St/Shell/Gvc/Shew/Mutter + AccountsService/Gdm/UPowerGlib/GWeather/Geoclue at
#      boot; a missing typelib throws at JS module load and the shell never paints.
#   3. The `angle` deb + gsettings-desktop-schemas installed; the Xios app (com.max.xios) present.
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

export PATH="$XS_PREFIX/local/bin:$XS_PREFIX/bin:$XS_PREFIX/sbin${XS_JB:+:$XS_JB/bin:$XS_JB/sbin}:$PATH"
# Match the PROVEN mutter smoke env exactly (run-mutter.sh): same runtime dir (so the rendezvous
# lands where the Xios app + this script expect), same dyld path, same HOME for dconf/state.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$XS_TMP}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export HOME="${HOME:-$XS_VAR/root}"
TMP="$XDG_RUNTIME_DIR"
ANGLE="${ANGLE:-$(jb_path /lib/angle)}"
PLUGINS="${PLUGINS:-$XS_PREFIX/lib/mutter-14/plugins}"
LIBEXEC="${LIBEXEC:-$XS_PREFIX/libexec}"
SHELL_BIN="${SHELL_BIN:-$XS_PREFIX/bin/gnome-shell}"
SHELL_LIB="${SHELL_LIB:-$XS_PREFIX/lib/gnome-shell}"
WSOCK="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
XIOS_JSON_PATH="${XIOS_JSON_PATH:-$TMP/xios.json}"
XIOS_DDX_SOCKET="${XIOS_DDX_SOCKET:-$TMP/mutter-ddx.sock}"
XIOS_INPUT_SOCKET="${XIOS_INPUT_SOCKET:-$TMP/mutter-input.sock}"
GNOME_SHELL_LOG="${GNOME_SHELL_LOG:-$TMP/gnome-shell.log}"

[ -x "$SHELL_BIN" ] || { echo "!! $SHELL_BIN missing — install the gnome-shell deb"; exit 1; }

# --- (0) GPU entitlement: gnome-shell drives ANGLE/Metal via MetaBackendIOS, so it needs the
#         SAME GPU + task_for_pid union the mutter smoke has, or MTLCreateSystemDefaultDevice
#         returns nil -> black screen (see fakesigned-metal-gpu-entitlement). The deb ships an
#         ad-hoc signature; re-sign with the union entitlement now. Idempotent.
echo "==> re-sign gnome-shell with the iosc-gl GPU union entitlement"
ENT=$TMP/iosc-gl-ent.xml
if [ -n "$XS_JB" ]; then
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
    <!-- gnome-shell runs gjs = mozjs-115 with the JIT. Executing JIT-generated (unsigned)
         code needs dynamic-codesigning, or AMFI CS_KILLs the process (SIGKILL, no crash
         report) the moment mozjs tiers a hot function up to baseline/Ion (~3s into boot). -->
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
ldid -e "$SHELL_BIN" 2>/dev/null | grep -q AGXDeviceUserClient || { echo "!! entitlements did not stick — abort"; exit 1; }

# --- (1) stop the mutter smoke / iosc / Xios app (gnome-shell replaces the compositor) ---------
if [ -z "${XIOS_SESSION_SLOT:-}" ]; then
  echo "==> stop the running compositor (mutter smoke or iosc) + the Xios app + any shell/clients"
  ps ax | grep -v grep | grep -E "Xios :| Xios$|/Xios\.app/Xios|bin/iosc|ioscbar|ioscdock|ioscoverview|/usr/bin/mutter|/usr/bin/gnome-shell|gnome-session" \
    | awk '{print $1}' | while read -r pid; do
        [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ] || kill -9 "$pid" 2>/dev/null
    done
  sleep 1
fi
rm -f "$WSOCK" "$WSOCK.lock" "$XIOS_DDX_SOCKET" "$XIOS_JSON_PATH" \
      "$XIOS_INPUT_SOCKET" "$TMP/xios-input.sock" "$GNOME_SHELL_LOG" 2>/dev/null

# --- (2) the so-name symlinks cogl's GLES driver + the mutter plugin loader need ---------------
echo "==> ANGLE + mutter-plugin so-name symlinks"
ln -sf libGLESv2.dylib "$ANGLE/libGLESv2.so.2" 2>/dev/null; ln -sf libGLESv2.dylib "$ANGLE/libGLESv2.so" 2>/dev/null
ln -sf libEGL.dylib    "$ANGLE/libEGL.so.1"    2>/dev/null; ln -sf libEGL.dylib    "$ANGLE/libEGL.so"   2>/dev/null
for f in "$PLUGINS"/*.dylib; do [ -e "$f" ] && ln -sf "$(basename "$f")" "${f%.dylib}.so" 2>/dev/null; done

echo "==> ensure GSettings schemas compiled"
[ -e "$XS_PREFIX/share/glib-2.0/schemas/gschemas.compiled" ] || \
  glib-compile-schemas "$XS_PREFIX/share/glib-2.0/schemas" 2>/dev/null || true

# --- (3) launch: ONE dbus-run-session holds the session bus; the freedesktop stubs claim their
#         SYSTEM-bus names on it (DBUS_SYSTEM_BUS_ADDRESS=session), then gnome-shell --wayland
#         brings up Mutter/MetaBackendIOS + the Xios rendezvous. gnome-shell is run DIRECTLY (not
#         via gnome-session) for the lowest-variable first light; switch to launch-gnome-session.sh
#         once it paints.
echo "==> start the session stubs + gnome-shell --wayland -> $GNOME_SHELL_LOG"
# Fully detach into a new session: gnome-shell is a GRANDCHILD (dbus-run-session -> sh -> gnome-shell)
# and nohup only shields the direct command — when this launcher's ssh session closes, SIGHUP reaches
# the grandchild and kills the shell ~16s after launch. The device has no `setsid`, so use a tiny
# python fork+setsid shim: it puts the whole tree in its own session with no controlling terminal,
# surviving the launcher/ssh exit. (Confirmed: attached/foreground runs live indefinitely; only the
# ssh-detach was killing it.)
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

# Timezone: glib/GNOME default to UTC unless the local zone is discoverable. iOS keeps the real
# zone at /var/db/timezone/localtime but doesn't expose a glib-readable /etc/localtime + zoneinfo
# dir. Wire glib's zoneinfo dir to iOS's tz database and derive TZ from the device's own zone, so
# the panel clock shows LOCAL time (this "unixy" wiring belongs in xios-fhs; done here meanwhile).
[ -e "$XS_PREFIX/share/zoneinfo" ] || ln -sf /var/db/timezone/zoneinfo "$XS_PREFIX/share/zoneinfo" 2>/dev/null
XIOS_TZ="$(readlink /var/db/timezone/localtime 2>/dev/null | sed 's#.*/zoneinfo/##')"
[ -n "$XIOS_TZ" ] && echo "==> timezone: $XIOS_TZ"

"$SETSID" env \
  ${XIOS_TZ:+TZ="$XIOS_TZ"} \
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" HOME="$HOME" \
  WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
  XIOS_DDX_SOCKET="$XIOS_DDX_SOCKET" \
  XIOS_JSON_PATH="$XIOS_JSON_PATH" \
  XIOS_INPUT_SOCKET="$XIOS_INPUT_SOCKET" \
  DYLD_LIBRARY_PATH="$XS_PREFIX/lib:$SHELL_LIB:$XS_PREFIX/lib/mutter-14:$ANGLE" \
  XDG_DATA_DIRS="$XS_PREFIX/share" \
  GSETTINGS_SCHEMA_DIR="$XS_PREFIX/share/glib-2.0/schemas" \
  XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME XDG_SESSION_CLASS=user \
  GDK_BACKEND=wayland CLUTTER_BACKEND=wayland \
  dbus-run-session -- sh -c '
    export DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"
    # Persist the (otherwise abstract) session bus address so out-of-session tools
    # (headless screenshots via org.gnome.Shell.Screenshot, gsettings, gdbus) can reach it.
    printf %s "$DBUS_SESSION_BUS_ADDRESS" > '"$TMP"'/gnome-session-bus'"${XIOS_SESSION_SLOT:+-$XIOS_SESSION_SLOT}"'
    [ -x '"$LIBEXEC"'/xios-login1-stub ]  && '"$LIBEXEC"'/xios-login1-stub &
    [ -x '"$LIBEXEC"'/xios-polkit-stub ]  && '"$LIBEXEC"'/xios-polkit-stub &
    [ -x '"$LIBEXEC"'/xios-accounts-stub ] && '"$LIBEXEC"'/xios-accounts-stub &
    [ -x '"$LIBEXEC"'/xios-hwbridged ]    && '"$LIBEXEC"'/xios-hwbridged &
    [ -x '"$LIBEXEC"'/xios-sensord ]      && '"$LIBEXEC"'/xios-sensord &
    [ -r '"$(jb_path /etc/profile.d/xios-pulse.sh)"' ] && . '"$(jb_path /etc/profile.d/xios-pulse.sh)"' && xios_pulse_start
    [ -x '"$LIBEXEC"'/xios-sysintd ]      && '"$LIBEXEC"'/xios-sysintd &
    sleep 1
    exec gnome-shell --wayland --wayland-display "$WAYLAND_DISPLAY"
  ' >"$GNOME_SHELL_LOG" 2>&1 </dev/null &
GPID=$!

echo "==> wait for gnome-shell to create the output IOSurface + write xios.json + serve wayland"
for _ in $(seq 1 100); do
  [ -f "$XIOS_JSON_PATH" ] && [ -S "$XIOS_DDX_SOCKET" ] && break
  kill -0 "$GPID" 2>/dev/null || break
  sleep 0.2
done
if ! kill -0 "$GPID" 2>/dev/null; then echo "!! gnome-shell died:"; sed 's/^/   /' "$GNOME_SHELL_LOG"; exit 1; fi
echo "   xios.json:       $(cat "$XIOS_JSON_PATH" 2>/dev/null)"
echo "   mutter-ddx.sock: $([ -S "$XIOS_DDX_SOCKET" ] && echo up || echo MISSING)"
echo "   wayland socket:  $(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | tr '\n' ' ')"

if chown mobile:mobile "$XIOS_DDX_SOCKET" 2>/dev/null || chown 501:501 "$XIOS_DDX_SOCKET" 2>/dev/null; then
  chmod 0660 "$XIOS_DDX_SOCKET" 2>/dev/null
else
  chmod 0600 "$XIOS_DDX_SOCKET" 2>/dev/null
  echo "!! could not hand $XIOS_DDX_SOCKET to mobile; keeping it owner-only"
fi

echo "==> relaunch the Xios app (adopts + Metal-presents gnome-shell's output IOSurface)"
uiopen -b com.max.xios 2>/dev/null
sleep 4

echo "==> gnome-shell log (look for: MetaRendererIOS create_view, IOSurface id=, JS ready; NOT"
echo "    'Failed to load module', typelib-not-found, or MTLCreateSystemDefaultDevice nil):"
sed 's/^/   /' "$GNOME_SHELL_LOG" | tail -80
echo "==> gnome-shell still running: $(kill -0 "$GPID" 2>/dev/null && echo yes || echo NO)"
echo
echo "SUCCESS = the iPad shows the GNOME Shell top panel + Activities + a wallpaper (not the flat"
echo "mutter-smoke fill). Input is not wired yet (mutter-ios-2's pointer pipeline), so it is"
echo "look-don't-touch. If it dies at a gi:// import, the gir batch (prereq 2) is incomplete; if"
echo "the screen is black but the process lives, the GPU entitlement (step 0) did not take."
