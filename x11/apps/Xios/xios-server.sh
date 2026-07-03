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
# For Xvfb bring-up/debug without the app display path, use x11-server.sh.
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
XIOS_AUDIO_PROFILE=$(jb_path /etc/profile.d/xios-audio.sh)
XIOS_PULSE_PROFILE=$(jb_path /etc/profile.d/xios-pulse.sh)
[ -r "$XIOS_PROFILE" ] && . "$XIOS_PROFILE"
[ -r "$XIOS_AUDIO_PROFILE" ] && . "$XIOS_AUDIO_PROFILE"
command -v xios_apply_display_profile >/dev/null 2>&1 && xios_apply_display_profile
command -v xios_prepare_runtime_dirs >/dev/null 2>&1 && xios_prepare_runtime_dirs
# Desktop audio: the pulse profile helper starts xios-audiod AND PulseAudio and
# exports PULSE_SERVER at the PA native socket, so we call it instead of the old
# xios_audio_start (which only started the XIOA daemon). Idempotent.
[ -r "$XIOS_PULSE_PROFILE" ] && . "$XIOS_PULSE_PROFILE" && xios_pulse_start

TMP="${XIOS_RUNTIME_TMP:-}"
if [ -z "$TMP" ]; then
  if [ -n "$JB" ]; then TMP="$(jb_path /tmp)"; else TMP=/var/tmp; fi
fi
DISP="${DISP:-:3}"
# iPad 7 native: 2160x1620 (4:3, same aspect as the screen) -> app displays 1:1, crisp.
W="${W:-2160}"; H="${H:-1620}"; DPI="${DPI:-264}"
apply_app_display_request() {
  REQ="$TMP/xios-request.json"
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
# The app runs as 'mobile' and needs write perm to connect() to the root-owned
# rendezvous socket. Restrict it to mobile; numeric 501 covers stripped images.
if chown mobile:mobile "$SOCK" 2>/dev/null || chown 501:501 "$SOCK" 2>/dev/null; then
  chmod 0660 "$SOCK" 2>/dev/null
else
  chmod 0600 "$SOCK" 2>/dev/null
  echo "!! could not hand $SOCK to mobile; keeping it owner-only"
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
