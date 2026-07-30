#!/usr/bin/env bash
# Start an Xvfb debug/headless X server. Runs ON THE DEVICE:
#   ssh root@ipad 'bash -s' < x11-server.sh        (or scp + run)
#
# This does not feed the Xios app display path. Use iosc/Xwayland for an
# interactive desktop. This script is only for debug clients that connect
# directly to Xvfb over the local X socket.
set -u

detect_jbroot() {
  if [ -n "${IOSC_JBROOT:-}" ]; then printf '%s\n' "${IOSC_JBROOT%/}"; return; fi
  if [ -n "${JBROOT:-}" ]; then printf '%s\n' "${JBROOT%/}"; return; fi
  if [ -n "${XIOS_PREFIX:-}" ]; then printf '%s\n' "${XIOS_PREFIX%/}"; return; fi
  if [ -d /var/jb/usr ]; then printf '%s\n' /var/jb; return; fi
  printf '%s\n' ''
}

jb_path() {
  case "$JB" in
    ''|/) printf '%s\n' "$1" ;;
    *)    printf '%s\n' "$JB$1" ;;
  esac
}

JB=$(detect_jbroot)
export PATH="$(jb_path /usr/bin):$(jb_path /usr/sbin):$(jb_path /bin):$(jb_path /sbin):$PATH"
export HOME=/var/root
XIOS_PROFILE=$(jb_path /etc/profile.d/xios.sh)
[ -r "$XIOS_PROFILE" ] && . "$XIOS_PROFILE"
command -v xios_apply_display_profile >/dev/null 2>&1 && xios_apply_display_profile
command -v xios_prepare_runtime_dirs >/dev/null 2>&1 && xios_prepare_runtime_dirs

FBDIR="${XIOS_RUNTIME_TMP:-}"
if [ -z "$FBDIR" ]; then
  if [ -n "$JB" ]; then FBDIR="$(jb_path /tmp)"; else FBDIR=/var/tmp; fi
fi
DISP="${DISP:-:3}"
# iPad 7 native: 2160x1620 (4:3, same aspect as the screen).
W="${W:-2160}"; H="${H:-1620}"; DPI="${DPI:-264}"
apply_app_display_request() {
  REQ="$FBDIR/xios-request.json"
  [ -r "$REQ" ] || return 0
  json_get() {
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p; s/.*\"$1\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" "$REQ" | head -n 1
  }
  rw="$(json_get width)"; rh="$(json_get height)"; rdpi="$(json_get dpi)"; rdisp="$(json_get display)"
  case "$rw" in ''|*[!0-9]*) ;; *) W="$rw";; esac
  case "$rh" in ''|*[!0-9]*) ;; *) H="$rh";; esac
  case "$rdpi" in ''|*[!0-9]*) ;; *) DPI="$rdpi";; esac
  case "$rdisp" in :*) DISP="$rdisp";; esac
}
apply_app_display_request
alive(){ ps ax 2>/dev/null | grep -v grep | grep -q "$1"; }

echo "==> starting Xvfb $DISP (${W}x${H}x24) -> $FBDIR/Xvfb_screen0"
DNUM="${DISP#:}"
PIDFILE="$FBDIR/.x11-clients-${DNUM}.pids"   # clients WE launched last run (by PID)
# pkill -f is unreliable on this device; kill by PID (ps first field, no awk needed).
# Scope every kill to THIS display: our own clients from last run (the pidfile) and
# the Xvfb bound to $DISP — never a global kill of fluxbox/xterm/etc., which would
# also take down any other X session running on the device.
if [ -f "$PIDFILE" ]; then
  while read -r pid; do [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null; done < "$PIDFILE"
  rm -f "$PIDFILE"
fi
ps ax | grep -v grep | grep -E "Xvfb ${DISP}( |\$)" | while read pid rest; do kill -9 "$pid" 2>/dev/null; done
sleep 1
rm -f "$FBDIR/Xvfb_screen0" "/tmp/.X${DNUM}-lock" "/tmp/.X11-unix/X${DNUM}" \
      "$FBDIR/.X11-unix/X${DNUM}" 2>/dev/null
# -nolisten tcp: no network listener, so the only way in is the local Unix socket.
# (-ac leaves local access open; the app + WM clients depend on it and we don't set
# up xauth cookies here. On this single-user device the local socket is the surface.)
nohup Xvfb "$DISP" -screen 0 "${W}x${H}x24" -fbdir "$FBDIR" -dpi "$DPI" -ac -nolisten tcp \
  >"$FBDIR/xvfb.log" 2>&1 &
sleep 3
if ! alive "Xvfb $DISP"; then echo "!! Xvfb failed:"; tail -8 "$FBDIR/xvfb.log"; exit 1; fi

# Debug sidecar for tools that want to know the display geometry.
printf '{"width":%d,"height":%d,"display":"%s","ddx":"xvfb-debug"}\n' "$W" "$H" "$DISP" > "$FBDIR/xios.json"

echo "==> launching a window manager + clients on $DISP"
export DISPLAY="$DISP" XAUTHORITY=/var/root/.Xauthority
command -v xios_load_xresources >/dev/null 2>&1 && xios_load_xresources
: > "$PIDFILE"   # record the PIDs we start so the next run kills exactly these
nohup fluxbox >"$FBDIR/fluxbox.log" 2>&1 & echo $! >> "$PIDFILE"
sleep 1
# a terminal in SF Mono (needs the x11-fonts-sf package), plus xeyes/clock
if command -v xterm >/dev/null; then
  nohup xterm -fa monospace -fs 20 -geometry 96x28+80+80 \
    -bg "#1d1f21" -fg "#c5c8c6" -title "SF Mono - X11 on iOS" >/dev/null 2>&1 & echo $! >> "$PIDFILE"
fi
nohup xeyes -geometry 360x360+1700+80 >/dev/null 2>&1 & echo $! >> "$PIDFILE"
nohup xclock -geometry 320x320+1740+1220 -update 1 >/dev/null 2>&1 & echo $! >> "$PIDFILE"

echo "==> Xvfb debug server up on $DISP. Connect X11 clients directly to this display."
echo "    framebuffer: $FBDIR/Xvfb_screen0   geometry: $FBDIR/xios.json"
