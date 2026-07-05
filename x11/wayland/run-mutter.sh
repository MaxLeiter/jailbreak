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
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$XS_TMP}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
TMP="$XDG_RUNTIME_DIR"
MUTTER="${MUTTER:-$XS_PREFIX/bin/mutter}"
ANGLE="${ANGLE:-$(jb_path /lib/angle)}"
PLUGINS="${PLUGINS:-$XS_PREFIX/lib/mutter-14/plugins}"
WSOCK="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
XIOS_JSON_PATH="${XIOS_JSON_PATH:-$TMP/xios.json}"
XIOS_DDX_SOCKET="${XIOS_DDX_SOCKET:-$TMP/mutter-ddx.sock}"
XIOS_INPUT_SOCKET="${XIOS_INPUT_SOCKET:-$TMP/mutter-input.sock}"
MUTTER_LOG="${MUTTER_LOG:-$TMP/mutter.log}"

[ -x "$MUTTER" ] || { echo "!! $MUTTER missing/not executable — scp out/mutter there first"; exit 1; }

if [ -z "${XIOS_SESSION_SLOT:-}" ]; then
  echo "==> stop the iosc demo (iosc + Xios app + shell + any client); mutter replaces the compositor"
  ps ax | grep -v grep | grep -E "Xios :| Xios$|/Xios\.app/Xios|bin/iosc|ioscbar|ioscdock|ioscoverview|/usr/bin/mutter" \
    | awk '{print $1}' | while read -r pid; do
        [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ] || kill -9 "$pid" 2>/dev/null
    done
  sleep 1
fi
rm -f "$WSOCK" "$WSOCK.lock" "$XIOS_DDX_SOCKET" "$XIOS_JSON_PATH" \
      "$XIOS_INPUT_SOCKET" "$TMP/xios-input.sock" "$MUTTER_LOG" 2>/dev/null

echo "==> ANGLE Linux so-name symlinks (cogl's GLES driver dlopens libGLESv2.so.2 / libEGL.so.1)"
ln -sf libGLESv2.dylib "$ANGLE/libGLESv2.so.2" 2>/dev/null
ln -sf libGLESv2.dylib "$ANGLE/libGLESv2.so"   2>/dev/null
ln -sf libEGL.dylib    "$ANGLE/libEGL.so.1"    2>/dev/null
ln -sf libEGL.dylib    "$ANGLE/libEGL.so"      2>/dev/null

echo "==> mutter plugin so-name symlink (the loader appends .so to the plugin name)"
for f in "$PLUGINS"/*.dylib; do [ -e "$f" ] && ln -sf "$(basename "$f")" "${f%.dylib}.so" 2>/dev/null; done

echo "==> ensure the GSettings schemas are compiled (postinst normally does this)"
if [ ! -e "$XS_PREFIX/share/glib-2.0/schemas/gschemas.compiled" ]; then
  glib-compile-schemas "$XS_PREFIX/share/glib-2.0/schemas" 2>/dev/null || true
fi

# Desktop audio (xios-audiod + PulseAudio, PULSE_SERVER export) before the
# compositor so clients launched under mutter find a live PA socket; the export
# is inherited by the dbus-run-session child below. Idempotent.
PULSE_PROFILE="$(jb_path /etc/profile.d/xios-pulse.sh)"
[ -r "$PULSE_PROFILE" ] && . "$PULSE_PROFILE" && xios_pulse_start

echo "==> start mutter --wayland (MetaBackendIOS) -> $MUTTER_LOG"
# DYLD_LIBRARY_PATH resolves @rpath leaf names: libmutter-14.dylib (usr/lib), the cogl/clutter/mtk
# sub-dylibs (usr/lib/mutter-14), and libGLESv2/libEGL (lib/angle). Mutter acquires org.gnome.Mutter*
# names -> needs a session bus (dbus-run-session). No DISPLAY/WAYLAND_DISPLAY (it CREATES wayland-0).
nohup env \
  XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
  XIOS_DDX_SOCKET="$XIOS_DDX_SOCKET" \
  XIOS_JSON_PATH="$XIOS_JSON_PATH" \
  XIOS_INPUT_SOCKET="$XIOS_INPUT_SOCKET" \
  DYLD_LIBRARY_PATH="$XS_PREFIX/lib:$XS_PREFIX/lib/mutter-14:$ANGLE" \
  XDG_DATA_DIRS="$XS_PREFIX/share" \
  GSETTINGS_SCHEMA_DIR="$XS_PREFIX/share/glib-2.0/schemas" \
  HOME="$XS_VAR/root" \
  dbus-run-session -- "$MUTTER" --wayland --wayland-display "$WAYLAND_DISPLAY" >"$MUTTER_LOG" 2>&1 </dev/null &
MPID=$!

echo "==> wait for mutter to create the output IOSurface + write xios.json + serve wayland"
for _ in $(seq 1 50); do
  [ -f "$XIOS_JSON_PATH" ] && [ -S "$XIOS_DDX_SOCKET" ] && break
  kill -0 "$MPID" 2>/dev/null || break
  sleep 0.2
done
if ! kill -0 "$MPID" 2>/dev/null; then echo "!! mutter died:"; sed 's/^/   /' "$MUTTER_LOG"; exit 1; fi
echo "   xios.json:       $(cat "$XIOS_JSON_PATH" 2>/dev/null)"
echo "   mutter-ddx.sock: $([ -S "$XIOS_DDX_SOCKET" ] && echo up || echo MISSING)"
echo "   wayland socket:  $(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | tr '\n' ' ')"

# the Xios app runs as mobile; let it connect to the (root) rendezvous socket
if chown mobile:mobile "$XIOS_DDX_SOCKET" 2>/dev/null || chown 501:501 "$XIOS_DDX_SOCKET" 2>/dev/null; then
  chmod 0660 "$XIOS_DDX_SOCKET" 2>/dev/null
else
  chmod 0600 "$XIOS_DDX_SOCKET" 2>/dev/null
  echo "!! could not hand $XIOS_DDX_SOCKET to mobile; keeping it owner-only"
fi

echo "==> relaunch the Xios app (adopts + Metal-presents mutter's output IOSurface)"
uiopen -b com.max.xios 2>/dev/null
for _ in $(seq 1 20); do
  grep -q "iosurface-zerocopy" "$TMP/xios-status.txt" 2>/dev/null && break
  sleep 0.5
done
echo "   app adopted IOSurface: $(grep -q iosurface-zerocopy "$TMP/xios-status.txt" 2>/dev/null && echo yes || echo NO)"

echo "==> mutter log (look for: MetaRendererIOS create_view, IOSurface id=, present):"
sed 's/^/   /' "$MUTTER_LOG"
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
