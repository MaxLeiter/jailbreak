#!/usr/bin/env bash
# Run GNOME Console (kgx) as a Wayland client against the iosc compositor, ON THE
# DEVICE (root). This is the "first real GNOME app on the Wayland GPU desktop"
# bring-up: iosc stands in for the X server (one fullscreen IOSurface the Xios app
# Metal-presents), and kgx — a libadwaita GtkApplication — maps an xdg_toplevel and
# paints through iosc. GApplication apps need a session bus ("Cannot autolaunch
# D-Bus without X11 $DISPLAY" otherwise), so kgx runs under dbus-run-session.
#
#   ssh root@ipad 'bash -s' < run-kgx.sh
set -u
export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:$PATH
export XDG_RUNTIME_DIR=/var/jb/tmp
TMP=/var/jb/tmp
[ -r /var/jb/etc/profile.d/xios.sh ] && . /var/jb/etc/profile.d/xios.sh
WSOCK="$XDG_RUNTIME_DIR/wayland-0"
BIN=/var/jb/usr/local/bin
SHELL_BIN=/var/jb/usr/bin/bash
# dbus-daemon refuses a world-writable (1777) XDG_RUNTIME_DIR for its service
# directory, so give the session bus a private mode-0700 dir of its own and point
# kgx at the wayland socket by absolute path (WAYLAND_DISPLAY may be a full path).
BUS_DIR="$TMP/kgxrun"

echo "==> stop any Xios X server, app, prior iosc, stray kgx + session bus"
# Anchor kgx/iosc to their binary paths (not "kgx" anywhere, which matches this
# script's own path when run as `bash /path/run-kgx.sh`) and never kill our own
# shell ($$) or parent ($PPID) — that self-kill aborted the run before iosc started.
ps ax | grep -v grep | grep -E "Xios :| Xios$|/Xios\.app/Xios|bin/iosc|bin/kgx|dbus-daemon.*--session" \
  | awk '{print $1}' | while read -r pid; do
      [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ] || kill -9 "$pid" 2>/dev/null
  done
sleep 1
rm -f "$WSOCK" "$WSOCK.lock" "$TMP/iosc-ddx.sock" "$TMP/xios.json" \
      "$TMP/iosc.log" "$TMP/kgx.log" 2>/dev/null

# Desktop audio (xios-audiod + PulseAudio, PULSE_SERVER export) before the
# compositor so kgx and any GTK client find a live PA socket. Idempotent.
[ -r /var/jb/etc/profile.d/xios-pulse.sh ] && . /var/jb/etc/profile.d/xios-pulse.sh && xios_pulse_start

echo "==> start iosc (compositor) -> $TMP/iosc.log"
nohup env XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR "$BIN/iosc" >"$TMP/iosc.log" 2>&1 </dev/null &
ICPID=$!
for _ in $(seq 1 30); do [ -S "$WSOCK" ] && [ -f "$TMP/xios.json" ] && break; sleep 0.2; done
if ! kill -0 "$ICPID" 2>/dev/null; then echo "!! iosc died:"; cat "$TMP/iosc.log"; exit 1; fi
chown mobile:mobile "$TMP/iosc-ddx.sock" 2>/dev/null && chmod 0660 "$TMP/iosc-ddx.sock" 2>/dev/null \
  || chmod 0777 "$TMP/iosc-ddx.sock" 2>/dev/null
echo "   wayland socket: $([ -S "$WSOCK" ] && echo up || echo MISSING)"
echo "   xios.json: $(cat "$TMP/xios.json" 2>/dev/null)"

echo "==> relaunch the Xios app (adopts iosc's IOSurface)"
# Use `uiopen -b <bundleid>` (open as if tapped, foreground), NOT the bare
# `uiopen <bundleid>` form: the latter returns 0 but FrontBoard suspends/kills the
# background-launched Metal app before it connects, so the app never adopts the
# IOSurface (status stays test-pattern, no ddx client in iosc.log). Then poll
# xios-status until the app reports it adopted the surface rather than a fixed sleep.
uiopen -b com.max.xios 2>/dev/null
for _ in $(seq 1 20); do
    grep -q "iosurface-zerocopy" "$TMP/xios-status.txt" 2>/dev/null && break
    sleep 0.5
done
echo "   app adopted IOSurface: $(grep -q "iosurface-zerocopy" "$TMP/xios-status.txt" 2>/dev/null && echo yes || echo NO)"
echo "   ddx client: $(grep 'client attached' "$TMP/iosc.log" 2>/dev/null | tail -1)"

echo "==> assert wayland socket is present before launching the client"
ls -l "$WSOCK" 2>&1 | sed 's/^/   /'
[ -S "$WSOCK" ] || { echo "!! wayland-0 socket missing — aborting"; exit 1; }

echo "==> run kgx under a session bus (GDK wayland, GSK renderer, a11y off) -> $TMP/kgx.log"
# NOTE: kgx MUST be launched with an explicit COMMAND (a bare `kgx` registers as the
# GApplication primary, runs startup, then returns 0 WITHOUT mapping a window in this
# headless/bus-only environment). Use the `-- <cmd> [args]` form, NOT `-e <cmd>`:
# `-e /var/jb/usr/bin/bash` makes VTE spawn a shell that exits immediately (no live
# child — a dead terminal), so typed keys reach kgx's wl_keyboard but go nowhere.
# `-- /var/jb/usr/bin/bash -i` spawns a real interactive bash that stays alive, maps an
# xdg_toplevel through iosc, and receives keystrokes via iosc's wl_keyboard → PTY.
rm -f "$TMP/kgx.exit"
mkdir -p "$BUS_DIR"; chmod 700 "$BUS_DIR"
# Client render path. DEFAULT ngl routes GTK's GL renderer through the wl_egl_window
# shim (ANGLE Metal -> IOSurface). Set IOSC_GSK_RENDERER=cairo for the wl_shm fallback.
GSK_SEL="${IOSC_GSK_RENDERER:-ngl}"
SHIM_ENV=""
[ "$GSK_SEL" = "cairo" ] || SHIM_ENV="ANGLE_REAL_LIBEGL=${ANGLE_REAL_LIBEGL:-/var/jb/lib/angle/libEGL.angle.dylib}"
nohup bash -c "
  env XDG_RUNTIME_DIR=$BUS_DIR WAYLAND_DISPLAY=$WSOCK \
    GDK_BACKEND=wayland GSK_RENDERER=$GSK_SEL $SHIM_ENV GSETTINGS_BACKEND=memory \
    GTK_A11Y=none HOME=/var/jb/var/root \
    dbus-run-session -- /var/jb/usr/bin/kgx -T iosc-kgx -- $SHELL_BIN -i
  echo \$? >$TMP/kgx.exit
" >"$TMP/kgx.log" 2>&1 </dev/null &
KGXPID=$!
sleep 9

echo "==> kgx exit code (EMPTY = still running = good):"; sed 's/^/   /' "$TMP/kgx.exit" 2>/dev/null
echo "==> iosc: kgx toplevel mapped?"; grep -E "toplevel title|toplevel app_id|surface mapped" "$TMP/iosc.log" | tail -4 | sed 's/^/   /'
echo "==> iosc: window painting (latest recomposite):"; grep "recomposited 1" "$TMP/iosc.log" | tail -1 | sed 's/^/   /'
echo "==> Xios app present:"; sed 's/^/   /' "$TMP/xios-status.txt" 2>/dev/null
echo "==> process tree (dbus -> kgx -> shell child):"
ps -ax -o pid,ppid,command | grep -v grep | grep -E "dbus-daemon|/usr/bin/kgx|/usr/bin/bash" | sed 's/^/   /'
echo "==> iosc running: $(kill -0 "$ICPID" 2>/dev/null && echo yes || echo NO)"
