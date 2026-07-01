#!/usr/bin/env bash
# Run Xwayland ROOTFUL as a Wayland client of the iosc compositor, ON THE DEVICE
# (root). This makes X11-only apps (xterm, and the marquee case hitori — a GTK3
# x11-backend-only app that CANNOT run under iosc directly today) usable inside
# the Wayland desktop.
#
# Chain (X0, software): X app -> X protocol -> Xwayland :1 (rootful, renders its
# whole root window in software) -> wl_shm buffer -> iosc -> IOSurface -> Xios
# app -> Metal. iosc sees ONE xdg_toplevel (the Xwayland root); an in-X window
# manager (fluxbox, or twm) manages the X clients INSIDE that root window.
#
#   ssh root@ipad 'bash -s' < run-xwayland.sh            # default: xterm
#   ssh root@ipad 'APP=hitori bash -s' < run-xwayland.sh # the GTK3 marquee case
#
# NB rootful (not rootless): rootless Xwayland needs the compositor to be an X
# window manager (an XWM), which iosc is not. Rootful shows the entire X screen
# as one surface and works under any compositor. (Mutter's built-in XWM is the
# later rootless path.)
set -u
export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:$PATH
export XDG_RUNTIME_DIR=/var/jb/tmp
TMP=/var/jb/tmp
[ -r /var/jb/etc/profile.d/xios.sh ] && . /var/jb/etc/profile.d/xios.sh
WSOCK="$XDG_RUNTIME_DIR/wayland-0"
BIN=/var/jb/usr/local/bin
XWL=/var/jb/usr/bin/Xwayland
XDISP=":1"
GEOM="${GEOM:-2160x1620}"
APP="${APP:-xterm}"

command -v "$XWL" >/dev/null 2>&1 || { echo "!! $XWL not installed (dpkg -i the xwayland deb first)"; exit 1; }

echo "==> stop any Xios X server, app, prior iosc, stray Xwayland/WM/clients"
ps ax | grep -v grep \
  | grep -E "Xios :| Xios$|/Xios\.app/Xios|iosc|Xwayland|fluxbox|twm| xterm|hitori" \
  | awk '{print $1}' | while read -r pid; do kill -9 "$pid" 2>/dev/null; done
sleep 1
rm -f "$WSOCK" "$WSOCK.lock" "$TMP/iosc-ddx.sock" "$TMP/xios.json" \
      "$TMP/iosc.log" "$TMP/xwl.log" "/tmp/.X11-unix/X1" 2>/dev/null

echo "==> start iosc (compositor) -> $TMP/iosc.log"
nohup env XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR "$BIN/iosc" >"$TMP/iosc.log" 2>&1 </dev/null &
ICPID=$!
for _ in $(seq 1 30); do [ -S "$WSOCK" ] && [ -f "$TMP/xios.json" ] && break; sleep 0.2; done
if ! kill -0 "$ICPID" 2>/dev/null; then echo "!! iosc died:"; cat "$TMP/iosc.log"; exit 1; fi
chmod 0777 "$TMP/iosc-ddx.sock" 2>/dev/null
echo "   wayland socket: $([ -S "$WSOCK" ] && echo up || echo MISSING)"

echo "==> relaunch the Xios app (adopts iosc's IOSurface)"
uiopen com.max.xios 2>/dev/null || uiopen -b com.max.xios 2>/dev/null
sleep 3
[ -S "$WSOCK" ] || { echo "!! wayland-0 socket missing — aborting"; exit 1; }

echo "==> start Xwayland $XDISP ROOTFUL as an iosc client -> $TMP/xwl.log"
# -rootful: whole X screen = one xdg_toplevel. -retro: classic stipple root (so a
# bare X screen is visibly non-black). -noreset: survive the last client exiting.
# -geometry sizes the X screen to the output. XWAYLAND_NO_GLAMOR belt-and-suspenders
# for the X0 (software) deb — the software build has no glamor anyway.
nohup env XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR WAYLAND_DISPLAY=wayland-0 XWAYLAND_NO_GLAMOR=1 \
  "$XWL" "$XDISP" -rootful -geometry "$GEOM" -retro -noreset \
  >"$TMP/xwl.log" 2>&1 </dev/null &
XWLPID=$!
# wait for the X display socket
for _ in $(seq 1 40); do [ -S "/tmp/.X11-unix/X1" ] && break; sleep 0.2; done
if ! kill -0 "$XWLPID" 2>/dev/null; then echo "!! Xwayland died:"; tail -20 "$TMP/xwl.log"; exit 1; fi
echo "   Xwayland mapped? (iosc log):"; grep -E "toplevel|surface mapped" "$TMP/iosc.log" | tail -3 | sed 's/^/     /'

export DISPLAY="$XDISP"
echo "==> start an X window manager inside the rootful root (fluxbox|twm, optional)"
for wm in fluxbox twm; do
  if command -v "$wm" >/dev/null 2>&1; then
    nohup "$wm" >"$TMP/xwm.log" 2>&1 </dev/null & echo "   started $wm"; break
  fi
done
sleep 1

echo "==> launch the X client: $APP (DISPLAY=$XDISP)"
case "$APP" in
  hitori) APPCMD="/var/jb/usr/bin/hitori" ;;
  xterm)  APPCMD="/var/jb/usr/bin/xterm -geometry 80x24+40+40 -e /var/jb/usr/bin/bash -i" ;;
  *)      APPCMD="$APP" ;;
esac
command -v "${APPCMD%% *}" >/dev/null 2>&1 || { echo "!! $APP not installed on device"; }
nohup env DISPLAY=$XDISP $APPCMD >"$TMP/xclient.log" 2>&1 </dev/null &
sleep 4

echo "==> STATE"
echo "   Xwayland alive: $(kill -0 "$XWLPID" 2>/dev/null && echo yes || echo NO)"
echo "   X clients (DISPLAY :1):"; DISPLAY=:1 xlsclients 2>/dev/null | sed 's/^/     /' || echo "     (xlsclients n/a)"
echo "   iosc recomposite (latest):"; grep -E "recomposited" "$TMP/iosc.log" | tail -1 | sed 's/^/     /'
echo "   Xios present:"; sed 's/^/     /' "$TMP/xios-status.txt" 2>/dev/null
echo "   Xwayland log tail:"; tail -6 "$TMP/xwl.log" | sed 's/^/     /'
echo "==> Physical on-screen check is Max's eyes: expect the $APP window on the iPad,"
echo "    inside the Xwayland rootful root (stipple background), composited through iosc."
