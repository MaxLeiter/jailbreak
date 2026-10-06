#!/usr/bin/env bash
# Run the iosc Wayland compositor on-device and point the Xios app at it. Runs ON
# THE DEVICE (root). The compositor stands in for the Xios X server: it creates one
# fullscreen IOSurface, writes $XS_TMP/xios.json so the app adopts it, and serves
# Wayland on wayland-0. Then we relaunch the app and a wl_shm client to paint it.
#
#   ssh root@ipad 'bash -s' < run-iosc.sh
set -u
# Resolve the jailbreak prefix. Prefer where this script is installed -- the iosc
# deb stages it under the prefix -- but fall back to probing, because the
# documented way to run this is `ssh root@ipad 'bash -s' < run-iosc.sh`, where
# the script has no path on disk at all. Set XS_JB= to force rootful.
#
# Slot-aware: with XIOS_SESSION_SLOT=<name> (or WAYLAND_DISPLAY=wayland-<name>) it
# brings up, and only ever restarts, that slot's compositor; every rendezvous
# path carries the slot name, exactly as xios-session lays them out. It no longer
# kills the Xios app or any other iosc on the device. Prefer
# `xios-session [--slot NAME] iosc` for real use: this is the dependency-free
# paint self-test.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ "${XS_JB+x}" != x ]; then
  case "${SCRIPT_DIR:-}/" in
    /var/jb/*) XS_JB=/var/jb ;;  # target-lint: allow-foreign-prefix
    *)         if [ -d /var/jb/usr ]; then XS_JB=/var/jb; else XS_JB=; fi ;;  # target-lint: allow-foreign-prefix
  esac
fi
XS_TMP="${XS_TMP:-${XS_JB:-/var}/tmp}"
export PATH=$XS_JB/usr/bin:$XS_JB/usr/sbin:$XS_JB/bin:$XS_JB/sbin:$PATH
export XDG_RUNTIME_DIR=$XS_TMP
TMP=$XS_TMP
BIN=$XS_JB/usr/local/bin

# Names for this slot (or the default session). The default session keeps the
# unsuffixed legacy names.
SLOT="${XIOS_SESSION_SLOT:-}"
if [ -z "$SLOT" ]; then
  case "${WAYLAND_DISPLAY:-wayland-0}" in
    wayland-0) ;;
    wayland-*) SLOT="${WAYLAND_DISPLAY#wayland-}" ;;
  esac
fi
if [ -n "$SLOT" ]; then
  WNAME="wayland-$SLOT"; SUF="-$SLOT"
else
  WNAME="wayland-0"; SUF=""
fi
WSOCK="$XDG_RUNTIME_DIR/$WNAME"
DDX="$TMP/iosc$SUF-ddx.sock"
JSON="$TMP/xios$SUF.json"
INPUT="$TMP/iosc$SUF-input.sock"
CLIP="$TMP/iosc$SUF-clipboard.sock"
WMS="$TMP/iosc$SUF-wm.sock"
ILOG="$TMP/iosc$SUF.log"
CLOG="$TMP/iosc-client$SUF.log"

echo "==> stop the previous iosc and test client of $WNAME (nothing else)"
# Only a compositor that carries THIS socket name is stopped, so a restart never
# touches another desktop or the Xios app. The test client has no argv to match,
# so it is found through its pid file.
ps axww -o pid=,command= | grep -v grep | grep -E "(^|[ /])iosc( |$)" \
  | while read -r pid rest; do
      [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ] && continue
      case "$rest" in
        *" -s $WNAME"|*" -s $WNAME "*) ;;
        *" -s "*) continue ;;
        *) [ "$WNAME" = wayland-0 ] || continue ;;
      esac
      kill -9 "$pid" 2>/dev/null
  done
if [ -f "$CLOG.pid" ]; then
  kill -9 "$(cat "$CLOG.pid")" 2>/dev/null
  rm -f "$CLOG.pid"
fi
sleep 1
rm -f "$WSOCK" "$WSOCK.lock" "$DDX" "$JSON" "$INPUT" "$CLIP" "$WMS" \
      "$ILOG" "$CLOG" "$TMP/iosc-shm-"* 2>/dev/null

# Logical desktop; iosc renders a 2x-oversized IOSurface the app supersamples down
# to the panel for the ~1.5 effective scale (Max-approved). Override via IOSC_LOGICAL.
IOSC_LOGICAL="${IOSC_LOGICAL:-1440x1080}"

# Bring up the desktop audio stack (xios-audiod + PulseAudio, PULSE_SERVER export)
# before the compositor so Wayland clients find a live PA socket. Idempotent.
[ -r $XS_JB/etc/profile.d/xios-pulse.sh ] && . $XS_JB/etc/profile.d/xios-pulse.sh && xios_pulse_start

echo "==> start iosc (compositor, logical $IOSC_LOGICAL) -> $ILOG"
# Every path is explicit so the argv names this compositor (the stop above and
# xios-session's slot ownership both key off it). A slot compositor never
# refuses on another session's active marker.
nohup env XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR \
  XIOS_SESSION_SLOT="$SLOT" \
  ${SLOT:+IOSC_IGNORE_ACTIVE_SESSION=1} \
  "$BIN/iosc" -logical "$IOSC_LOGICAL" -s "$WNAME" \
    -ddx-sock "$DDX" -json "$JSON" -input-sock "$INPUT" \
    -clipboard-sock "$CLIP" -wm-sock "$WMS" >"$ILOG" 2>&1 &
ICPID=$!
# wait for the wayland socket + the app handshake json
for _ in $(seq 1 30); do [ -S "$WSOCK" ] && [ -f "$JSON" ] && break; sleep 0.2; done
if ! kill -0 "$ICPID" 2>/dev/null; then echo "!! iosc died:"; cat "$ILOG"; exit 1; fi
# the app runs as mobile; let it connect to the (root) rendezvous socket
if chown mobile:mobile "$DDX" 2>/dev/null || chown 501:501 "$DDX" 2>/dev/null; then
  chmod 0660 "$DDX" 2>/dev/null
else
  chmod 0600 "$DDX" 2>/dev/null
  echo "!! could not hand $DDX to mobile; keeping it owner-only"
fi
echo "   wayland socket: $([ -S "$WSOCK" ] && echo up || echo MISSING)"
echo "   json: $(cat "$JSON" 2>/dev/null)"

echo "==> relaunch the Xios app (adopts iosc's IOSurface)"
uiopen -b com.max.xios 2>/dev/null || uiopen com.max.xios 2>/dev/null
J="$(cat "$JSON" 2>/dev/null)"
JW="$(printf '%s' "$J" | sed -n 's/.*"width":\([0-9][0-9]*\).*/\1/p')"
JH="$(printf '%s' "$J" | sed -n 's/.*"height":\([0-9][0-9]*\).*/\1/p')"
for _ in $(seq 1 20); do
  grep -q "iosurface-zerocopy ${JW}x${JH}" "$TMP/xios-status.txt" 2>/dev/null && break
  sleep 0.5
done

echo "==> run iosc-client (paints a wl_shm frame) -> $CLOG"
nohup env XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR WAYLAND_DISPLAY="$WNAME" \
  "$BIN/iosc-client" >"$CLOG" 2>&1 &
echo $! >"$CLOG.pid"
sleep 2

echo "==> iosc log:";        sed 's/^/   /' "$ILOG"
echo "==> client log:";      sed 's/^/   /' "$CLOG"
echo "==> app status:";      sed 's/^/   /' "$TMP/xios-status.txt" 2>/dev/null
echo "==> app geom:";        sed 's/^/   /' "$TMP/xios-geom.txt" 2>/dev/null
echo "==> iosc still running: $(kill -0 "$ICPID" 2>/dev/null && echo yes || echo NO)"
