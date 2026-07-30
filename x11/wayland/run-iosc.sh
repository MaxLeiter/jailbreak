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
WSOCK="$XDG_RUNTIME_DIR/wayland-0"
BIN=$XS_JB/usr/local/bin

echo "==> stop any Xios X server, app, prior iosc, and test clients"
# Anchor iosc to binary paths (plain "iosc" matches this script's own path when
# run over SSH) and never kill our own shell or parent.
ps ax | grep -v grep | grep -E "/Xios\.app/Xios|(^|[ /])iosc( |$)|(^|[ /])iosc-client( |$)" \
  | awk '{print $1}' | while read -r pid; do
      [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ] || kill -9 "$pid" 2>/dev/null
  done
sleep 1
rm -f "$WSOCK" "$WSOCK.lock" "$TMP/iosc-ddx.sock" "$TMP/iosc-native-ddx.sock" \
      "$TMP/iosc-native.sock" "$TMP/xios.json" "$TMP/xios-native.json" \
      "$TMP/iosc.log" "$TMP/iosc-client.log" "$TMP/iosc-shm-"* 2>/dev/null

# Logical desktop; iosc renders a 2x-oversized IOSurface the app supersamples down
# to the panel for the ~1.5 effective scale (Max-approved). Override via IOSC_LOGICAL.
IOSC_LOGICAL="${IOSC_LOGICAL:-1440x1080}"

# Bring up the desktop audio stack (xios-audiod + PulseAudio, PULSE_SERVER export)
# before the compositor so Wayland clients find a live PA socket. Idempotent.
[ -r $XS_JB/etc/profile.d/xios-pulse.sh ] && . $XS_JB/etc/profile.d/xios-pulse.sh && xios_pulse_start

echo "==> start iosc (compositor, logical $IOSC_LOGICAL) -> $TMP/iosc.log"
nohup env XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR "$BIN/iosc" -logical "$IOSC_LOGICAL" >"$TMP/iosc.log" 2>&1 &
ICPID=$!
# wait for the wayland socket + the app handshake json
for _ in $(seq 1 30); do [ -S "$WSOCK" ] && [ -f "$TMP/xios.json" ] && break; sleep 0.2; done
if ! kill -0 "$ICPID" 2>/dev/null; then echo "!! iosc died:"; cat "$TMP/iosc.log"; exit 1; fi
# the app runs as mobile; let it connect to the (root) rendezvous socket
if chown mobile:mobile "$TMP/iosc-ddx.sock" 2>/dev/null || chown 501:501 "$TMP/iosc-ddx.sock" 2>/dev/null; then
  chmod 0660 "$TMP/iosc-ddx.sock" 2>/dev/null
else
  chmod 0600 "$TMP/iosc-ddx.sock" 2>/dev/null
  echo "!! could not hand $TMP/iosc-ddx.sock to mobile; keeping it owner-only"
fi
echo "   wayland socket: $([ -S "$WSOCK" ] && echo up || echo MISSING)"
echo "   xios.json: $(cat "$TMP/xios.json" 2>/dev/null)"

echo "==> relaunch the Xios app (adopts iosc's IOSurface)"
uiopen -b com.max.xios 2>/dev/null || uiopen com.max.xios 2>/dev/null
J="$(cat "$TMP/xios.json" 2>/dev/null)"
JW="$(printf '%s' "$J" | sed -n 's/.*"width":\([0-9][0-9]*\).*/\1/p')"
JH="$(printf '%s' "$J" | sed -n 's/.*"height":\([0-9][0-9]*\).*/\1/p')"
for _ in $(seq 1 20); do
  grep -q "iosurface-zerocopy ${JW}x${JH}" "$TMP/xios-status.txt" 2>/dev/null && break
  sleep 0.5
done

echo "==> run iosc-client (paints a wl_shm frame) -> $TMP/iosc-client.log"
nohup env XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR WAYLAND_DISPLAY=wayland-0 \
  "$BIN/iosc-client" >"$TMP/iosc-client.log" 2>&1 &
sleep 2

echo "==> iosc log:";        sed 's/^/   /' "$TMP/iosc.log"
echo "==> client log:";      sed 's/^/   /' "$TMP/iosc-client.log"
echo "==> app status:";      sed 's/^/   /' "$TMP/xios-status.txt" 2>/dev/null
echo "==> app geom:";        sed 's/^/   /' "$TMP/xios-geom.txt" 2>/dev/null
echo "==> iosc still running: $(kill -0 "$ICPID" 2>/dev/null && echo yes || echo NO)"
