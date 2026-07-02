#!/usr/bin/env bash
# run-mutter.sh — first-pixels smoke for Mutter 46 + MetaBackendIOS on-device (ROOT).
#
# Mutter is its OWN compositor and a drop-in for iosc here: MetaBackendIOS::constructed creates
# one fullscreen 2160x1620 output IOSurface, starts the Xios rendezvous server on
# /var/jb/tmp/mutter-ddx.sock, and writes /var/jb/tmp/xios.json so the Xios app adopts + Metal-
# presents that surface (exactly what iosc does). We stop the iosc demo first (mutter replaces it),
# start mutter --wayland, then relaunch the Xios app to show mutter's output. Route A: the stage
# renders into the output IOSurface as FBO 0 via a CoglOnscreen pbuffer (no EGLImage) and presents
# with finish + xios_notify_dirty.
#
#   ssh root@ipad 'bash -s' < run-mutter.sh
#
# PREREQS on device: libmutter-14-0 deb installed (schemas compiled by its postinst); the `angle`
# deb installed; gsettings-desktop-schemas installed; the Xios app (com.max.xios) present; and the
# route-A mutter binary at $MUTTER (scp x11/linux-build/out/mutter -> /var/jb/usr/bin/mutter; it is
# already ldid-signed with the iosc-gl union entitlement: task_for_pid + system-task-ports for the
# Xios mach handshake + AGX/IOGPU/IOSurface user clients for ANGLE-Metal, no-container OFF).
set -u
export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:$PATH
export XDG_RUNTIME_DIR=/var/jb/tmp
TMP=/var/jb/tmp
MUTTER="${MUTTER:-/var/jb/usr/bin/mutter}"
ANGLE=/var/jb/lib/angle
PLUGINS=/var/jb/usr/lib/mutter-14/plugins
WSOCK="$XDG_RUNTIME_DIR/wayland-0"

[ -x "$MUTTER" ] || { echo "!! $MUTTER missing/not executable — scp out/mutter there first"; exit 1; }

echo "==> stop the iosc demo (iosc + Xios app + shell + any client); mutter replaces the compositor"
ps ax | grep -v grep | grep -E "Xios :| Xios$|/Xios\.app/Xios|bin/iosc|ioscbar|ioscdock|ioscoverview|/usr/bin/mutter" \
  | awk '{print $1}' | while read -r pid; do
      [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ] || kill -9 "$pid" 2>/dev/null
  done
sleep 1
rm -f "$WSOCK" "$WSOCK.lock" "$TMP/mutter-ddx.sock" "$TMP/xios.json" \
      "$TMP/mutter-input.sock" "$TMP/xios-input.sock" "$TMP/mutter.log" 2>/dev/null

echo "==> ANGLE Linux so-name symlinks (cogl's GLES driver dlopens libGLESv2.so.2 / libEGL.so.1)"
ln -sf libGLESv2.dylib "$ANGLE/libGLESv2.so.2" 2>/dev/null
ln -sf libGLESv2.dylib "$ANGLE/libGLESv2.so"   2>/dev/null
ln -sf libEGL.dylib    "$ANGLE/libEGL.so.1"    2>/dev/null
ln -sf libEGL.dylib    "$ANGLE/libEGL.so"      2>/dev/null

echo "==> mutter plugin so-name symlink (the loader appends .so to the plugin name)"
for f in "$PLUGINS"/*.dylib; do [ -e "$f" ] && ln -sf "$(basename "$f")" "${f%.dylib}.so" 2>/dev/null; done

echo "==> ensure the GSettings schemas are compiled (postinst normally does this)"
if [ ! -e /var/jb/usr/share/glib-2.0/schemas/gschemas.compiled ]; then
  glib-compile-schemas /var/jb/usr/share/glib-2.0/schemas 2>/dev/null || true
fi

echo "==> start mutter --wayland (MetaBackendIOS) -> $TMP/mutter.log"
# DYLD_LIBRARY_PATH resolves @rpath leaf names: libmutter-14.dylib (usr/lib), the cogl/clutter/mtk
# sub-dylibs (usr/lib/mutter-14), and libGLESv2/libEGL (lib/angle). Mutter acquires org.gnome.Mutter*
# names -> needs a session bus (dbus-run-session). No DISPLAY/WAYLAND_DISPLAY (it CREATES wayland-0).
nohup env \
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
  DYLD_LIBRARY_PATH="/var/jb/usr/lib:/var/jb/usr/lib/mutter-14:$ANGLE" \
  XDG_DATA_DIRS=/var/jb/usr/share \
  GSETTINGS_SCHEMA_DIR=/var/jb/usr/share/glib-2.0/schemas \
  HOME=/var/jb/var/root \
  dbus-run-session -- "$MUTTER" --wayland >"$TMP/mutter.log" 2>&1 </dev/null &
MPID=$!

echo "==> wait for mutter to create the output IOSurface + write xios.json + serve wayland"
for _ in $(seq 1 50); do
  [ -f "$TMP/xios.json" ] && [ -S "$TMP/mutter-ddx.sock" ] && break
  kill -0 "$MPID" 2>/dev/null || break
  sleep 0.2
done
if ! kill -0 "$MPID" 2>/dev/null; then echo "!! mutter died:"; sed 's/^/   /' "$TMP/mutter.log"; exit 1; fi
echo "   xios.json:       $(cat "$TMP/xios.json" 2>/dev/null)"
echo "   mutter-ddx.sock: $([ -S "$TMP/mutter-ddx.sock" ] && echo up || echo MISSING)"
echo "   wayland socket:  $(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | tr '\n' ' ')"

# the Xios app runs as mobile; let it connect to the (root) rendezvous socket
chown mobile:mobile "$TMP/mutter-ddx.sock" 2>/dev/null && chmod 0660 "$TMP/mutter-ddx.sock" 2>/dev/null \
  || chmod 0777 "$TMP/mutter-ddx.sock" 2>/dev/null

echo "==> relaunch the Xios app (adopts + Metal-presents mutter's output IOSurface)"
uiopen -b com.max.xios 2>/dev/null
for _ in $(seq 1 20); do
  grep -q "iosurface-zerocopy" "$TMP/xios-status.txt" 2>/dev/null && break
  sleep 0.5
done
echo "   app adopted IOSurface: $(grep -q iosurface-zerocopy "$TMP/xios-status.txt" 2>/dev/null && echo yes || echo NO)"

echo "==> mutter log (look for: MetaRendererIOS create_view, IOSurface id=, present):"
sed 's/^/   /' "$TMP/mutter.log"
echo "==> Xios app status:"; sed 's/^/   /' "$TMP/xios-status.txt" 2>/dev/null
echo "==> mutter still running: $(kill -0 "$MPID" 2>/dev/null && echo yes || echo NO)"
echo
echo "SUCCESS (first pixels) = the iPad shows mutter's clutter stage (a solid fill from the default"
echo "plugin — no gnome-shell yet, so expect a flat background, NOT a rich desktop), mutter.log shows"
echo "MetaRendererIOS create_view WITHOUT the old 'eglCreateImageKHR(GL_TEXTURE_2D) 0x3000' /"
echo "'failed to wrap the output IOSurface as an ANGLE pbuffer' errors, xios-status.txt says"
echo "iosurface-zerocopy, and mutter stays up (0% CPU idle). That proves stage -> IOSurface FBO 0 ->"
echo "ANGLE/Metal -> Xios present end-to-end. A real WINDOW is the next step (run a Wayland client"
echo "against mutter's wayland-0, same pattern as run-kgx.sh: dbus-run-session -- kgx ...)."
echo "WATCH-ITEM: if the frame is vertically MIRRORED, that's the Cogl-onscreen Y-flip convention"
echo "(bottom-left FBO 0 vs the app's top-left IOSurface sampling) — a one-line fix, ping mutter-ios-2."
