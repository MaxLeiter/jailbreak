#!/usr/bin/env bash
# Start the native IOSurface X server ("Xios") that backs the Xios app — the
# zero-copy path. Runs ON THE DEVICE:
#   ssh root@ipad 'bash -s' < xios-server.sh        (or scp + run)
#
# Xios renders straight into a shared IOSurface; the app maps it into a Metal
# texture via a mach-port hand-off (no per-frame upload). Xios itself writes
# /var/jb/tmp/xios.json ({..."ddx":"iosurface"...}) which tells the app to use the
# zero-copy path and where the rendezvous socket is. Input comes via XTEST.
#
# For the old file-mmap fallback instead, use x11-server.sh (launches Xvfb -fbdir).
set -u
export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:$PATH
export HOME=/var/root
[ -r /var/jb/etc/profile.d/xios.sh ] && . /var/jb/etc/profile.d/xios.sh
command -v xios_apply_display_profile >/dev/null 2>&1 && xios_apply_display_profile
command -v xios_prepare_runtime_dirs >/dev/null 2>&1 && xios_prepare_runtime_dirs

DISP="${DISP:-:3}"
# iPad 7 native: 2160x1620 (4:3, same aspect as the screen) -> app displays 1:1, crisp.
W="${W:-2160}"; H="${H:-1620}"; DPI="${DPI:-264}"
TMP=/var/jb/tmp
SOCK="$TMP/xios-ddx.sock"
alive(){ ps ax 2>/dev/null | grep -v grep | grep -q "$1"; }

echo "==> starting Xios $DISP (${W}x${H}x24) -> IOSurface (zero-copy)"
DNUM="${DISP#:}"
PIDFILE="$TMP/.xios-clients-${DNUM}.pids"   # clients WE launched last run (by PID)
# pkill -f is unreliable on this device; kill by PID. Scope every kill to THIS
# display: our own clients from last run (the pidfile) and the X server bound to
# $DISP — never a global kill of fluxbox/xterm/etc. (would nuke other sessions).
if [ -f "$PIDFILE" ]; then
  while read -r pid; do [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null; done < "$PIDFILE"
  rm -f "$PIDFILE"
fi
ps ax | grep -v grep | grep -E "X(ios|vfb) ${DISP}( |\$)" | while read pid rest; do kill -9 "$pid" 2>/dev/null; done
sleep 1
rm -f "$SOCK" "/tmp/.X${DNUM}-lock" "/tmp/.X11-unix/X${DNUM}" \
      "$TMP/.X11-unix/X${DNUM}" "$TMP/xios.json" 2>/dev/null

# -noreset: don't regenerate when the last client disconnects (the IOSurface +
# socket persist for the app across client churn).
# -nolisten tcp: no network listener, so the only way in is the local Unix socket.
# (-ac leaves local access open; the app + WM clients depend on it and we don't set
# up xauth cookies here. On this single-user device the local socket is the surface.)
nohup Xios "$DISP" -screen 0 "${W}x${H}x24" -iosurface -dpi "$DPI" -ac -nolisten tcp -noreset \
  >"$TMP/xios-server.log" 2>&1 &
sleep 3
if ! alive "Xios $DISP"; then echo "!! Xios failed:"; tail -20 "$TMP/xios-server.log"; exit 1; fi
# The app runs as 'mobile' and needs write perm to connect() to the (root-owned)
# rendezvous socket. Restrict it to mobile (Xios does the same) rather than world:
# chown to mobile + 0660, falling back to 0777 only if that user can't be resolved
# (so the app is never locked out). The mach-port hand-off still verifies the peer.
if chown mobile:mobile "$SOCK" 2>/dev/null; then
  chmod 0660 "$SOCK" 2>/dev/null
else
  chmod 0777 "$SOCK" 2>/dev/null
fi
echo "   xios.json: $(cat "$TMP/xios.json" 2>/dev/null)"

echo "==> launching a window manager + clients on $DISP"
export DISPLAY="$DISP" XAUTHORITY=/var/root/.Xauthority
command -v xios_load_xresources >/dev/null 2>&1 && xios_load_xresources
: > "$PIDFILE"   # record the PIDs we start so the next run kills exactly these
nohup fluxbox >"$TMP/fluxbox.log" 2>&1 & echo $! >> "$PIDFILE"
sleep 1
if command -v xterm >/dev/null; then
  nohup xterm -fa monospace -fs 20 -geometry 96x28+80+80 \
    -bg "#1d1f21" -fg "#c5c8c6" -title "SF Mono - X11 on iOS" >/dev/null 2>&1 & echo $! >> "$PIDFILE"
fi
nohup xeyes -geometry 360x360+1700+80 >/dev/null 2>&1 & echo $! >> "$PIDFILE"
nohup xclock -geometry 320x320+1740+1220 -update 1 >/dev/null 2>&1 & echo $! >> "$PIDFILE"

echo "==> Xios up on $DISP. Open the X11 app on the iPad to see it."
echo "    IOSurface socket: $SOCK   server log: $TMP/xios-server.log"
