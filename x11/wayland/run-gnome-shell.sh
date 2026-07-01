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
export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:$PATH
# Match the PROVEN mutter smoke env exactly (run-mutter.sh): same runtime dir (so the rendezvous
# lands where the Xios app + this script expect), same dyld path, same HOME for dconf/state.
export XDG_RUNTIME_DIR=/var/jb/tmp
export HOME=/var/jb/var/root
TMP=/var/jb/tmp
ANGLE=/var/jb/lib/angle
PLUGINS=/var/jb/usr/lib/mutter-14/plugins
LIBEXEC=/var/jb/usr/libexec
SHELL_BIN=/var/jb/usr/bin/gnome-shell
WSOCK="$XDG_RUNTIME_DIR/wayland-0"

[ -x "$SHELL_BIN" ] || { echo "!! $SHELL_BIN missing — install the gnome-shell deb"; exit 1; }

# --- (0) GPU entitlement: gnome-shell drives ANGLE/Metal via MetaBackendIOS, so it needs the
#         SAME GPU + task_for_pid union the mutter smoke has, or MTLCreateSystemDefaultDevice
#         returns nil -> black screen (see fakesigned-metal-gpu-entitlement). The deb ships an
#         ad-hoc signature; re-sign with the union entitlement now. Idempotent.
echo "==> re-sign gnome-shell with the iosc-gl GPU union entitlement"
ENT=$TMP/iosc-gl-ent.xml
cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>platform-application</key><true/>
    <key>com.apple.private.amfi.can-allow-non-platform</key><true/>
    <key>com.apple.private.skip-library-validation</key><true/>
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
    <array><string>/var/jb/</string><string>/tmp/</string><string>/var/</string><string>/private/var/</string></array>
</dict>
</plist>
PLIST
ldid -S"$ENT" "$SHELL_BIN" && echo "   signed: $SHELL_BIN"
ldid -e "$SHELL_BIN" 2>/dev/null | grep -q AGXDeviceUserClient || { echo "!! entitlements did not stick — abort"; exit 1; }

# --- (1) stop the mutter smoke / iosc / Xios app (gnome-shell replaces the compositor) ---------
echo "==> stop the running compositor (mutter smoke or iosc) + the Xios app + any panel/clients"
ps ax | grep -v grep | grep -E "Xios :| Xios$|/Xios\.app/Xios|bin/iosc|ioscpanel|ioscoverview|/usr/bin/mutter|/usr/bin/gnome-shell|gnome-session" \
  | awk '{print $1}' | while read -r pid; do
      [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ] || kill -9 "$pid" 2>/dev/null
  done
sleep 1
rm -f "$WSOCK" "$WSOCK.lock" "$TMP/mutter-ddx.sock" "$TMP/xios.json" \
      "$TMP/xios-input.sock" "$TMP/gnome-shell.log" 2>/dev/null

# --- (2) the so-name symlinks cogl's GLES driver + the mutter plugin loader need ---------------
echo "==> ANGLE + mutter-plugin so-name symlinks"
ln -sf libGLESv2.dylib "$ANGLE/libGLESv2.so.2" 2>/dev/null; ln -sf libGLESv2.dylib "$ANGLE/libGLESv2.so" 2>/dev/null
ln -sf libEGL.dylib    "$ANGLE/libEGL.so.1"    2>/dev/null; ln -sf libEGL.dylib    "$ANGLE/libEGL.so"   2>/dev/null
for f in "$PLUGINS"/*.dylib; do [ -e "$f" ] && ln -sf "$(basename "$f")" "${f%.dylib}.so" 2>/dev/null; done

echo "==> ensure GSettings schemas compiled"
[ -e /var/jb/usr/share/glib-2.0/schemas/gschemas.compiled ] || \
  glib-compile-schemas /var/jb/usr/share/glib-2.0/schemas 2>/dev/null || true

# --- (3) launch: ONE dbus-run-session holds the session bus; the freedesktop stubs claim their
#         SYSTEM-bus names on it (DBUS_SYSTEM_BUS_ADDRESS=session), then gnome-shell --wayland
#         brings up Mutter/MetaBackendIOS + the Xios rendezvous. gnome-shell is run DIRECTLY (not
#         via gnome-session) for the lowest-variable first light; switch to launch-gnome-session.sh
#         once it paints.
echo "==> start the session stubs + gnome-shell --wayland -> $TMP/gnome-shell.log"
nohup env \
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" HOME="$HOME" \
  DYLD_LIBRARY_PATH="/var/jb/usr/lib:/var/jb/usr/lib/mutter-14:$ANGLE" \
  XDG_DATA_DIRS=/var/jb/usr/share \
  GSETTINGS_SCHEMA_DIR=/var/jb/usr/share/glib-2.0/schemas \
  XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME XDG_SESSION_CLASS=user \
  GDK_BACKEND=wayland CLUTTER_BACKEND=wayland \
  G_MESSAGES_DEBUG=all \
  dbus-run-session -- sh -c '
    export DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"
    [ -x '"$LIBEXEC"'/xios-login1-stub ]  && '"$LIBEXEC"'/xios-login1-stub &
    [ -x '"$LIBEXEC"'/xios-polkit-stub ]  && '"$LIBEXEC"'/xios-polkit-stub &
    [ -x '"$LIBEXEC"'/xios-accounts-stub ] && '"$LIBEXEC"'/xios-accounts-stub &
    [ -x '"$LIBEXEC"'/xios-hwbridged ]    && '"$LIBEXEC"'/xios-hwbridged &
    export PULSE_SERVER="${PULSE_SERVER:-unix:/var/jb/tmp/pulse/native}"
    [ -x '"$LIBEXEC"'/xios-sysintd ]      && '"$LIBEXEC"'/xios-sysintd &
    sleep 1
    exec gnome-shell --wayland
  ' >"$TMP/gnome-shell.log" 2>&1 </dev/null &
GPID=$!

echo "==> wait for gnome-shell to create the output IOSurface + write xios.json + serve wayland"
for _ in $(seq 1 100); do
  [ -f "$TMP/xios.json" ] && [ -S "$TMP/mutter-ddx.sock" ] && break
  kill -0 "$GPID" 2>/dev/null || break
  sleep 0.2
done
if ! kill -0 "$GPID" 2>/dev/null; then echo "!! gnome-shell died:"; sed 's/^/   /' "$TMP/gnome-shell.log"; exit 1; fi
echo "   xios.json:       $(cat "$TMP/xios.json" 2>/dev/null)"
echo "   mutter-ddx.sock: $([ -S "$TMP/mutter-ddx.sock" ] && echo up || echo MISSING)"
echo "   wayland socket:  $(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | tr '\n' ' ')"

chown mobile:mobile "$TMP/mutter-ddx.sock" 2>/dev/null && chmod 0660 "$TMP/mutter-ddx.sock" 2>/dev/null \
  || chmod 0777 "$TMP/mutter-ddx.sock" 2>/dev/null

echo "==> relaunch the Xios app (adopts + Metal-presents gnome-shell's output IOSurface)"
uiopen -b com.max.xios 2>/dev/null
sleep 4

echo "==> gnome-shell log (look for: MetaRendererIOS create_view, IOSurface id=, JS ready; NOT"
echo "    'Failed to load module', typelib-not-found, or MTLCreateSystemDefaultDevice nil):"
sed 's/^/   /' "$TMP/gnome-shell.log" | tail -80
echo "==> gnome-shell still running: $(kill -0 "$GPID" 2>/dev/null && echo yes || echo NO)"
echo
echo "SUCCESS = the iPad shows the GNOME Shell top panel + Activities + a wallpaper (not the flat"
echo "mutter-smoke fill). Input is not wired yet (mutter-ios-2's pointer pipeline), so it is"
echo "look-don't-touch. If it dies at a gi:// import, the gir batch (prereq 2) is incomplete; if"
echo "the screen is black but the process lives, the GPU entitlement (step 0) did not take."
