#!/bin/sh
#
# run-shell.sh — start the iosc desktop shell ON DEVICE.
#
# Brings up the full lightweight desktop: the iosc compositor, then the shell
# layer-shell clients (wallpaper, panel). The overview is spawned on demand by
# the panel's ⊞ button / QS "Overview" (or run `ioscoverview` yourself).
#
#   1. iosc        the compositor (skipped if a wayland-0 socket already lives —
#                  e.g. wayland/run-iosc.sh or ioscd already started it; open the
#                  Xios app to see the output either way)
#   2. ioscbg      wallpaper (background layer)
#   3. ioscpanel   panel + quick settings (top layer)
#
# Usage:  run-shell.sh [--no-compositor]
# Env:    IOSC_PANEL_SCALE (default 2), IOSC_WALLPAPER, IOSC_SHELL_ICONS,
#         IOSC_PANEL_OPACITY (once iosc blends layer surfaces)
#
# This is the future `xios-iosc` flavor: iosc + these clients are the whole
# desktop — no Mutter, no JS, pure C/Wayland. Package: package-shell.sh.
set -e

JB=/var/jb
BIN=$JB/usr/local/bin
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$JB/tmp}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export IOSC_PANEL_SCALE="${IOSC_PANEL_SCALE:-2}"

SOCK="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
log() { echo "run-shell: $*" >&2; }

# -- 1. compositor -----------------------------------------------------------
if [ "${1:-}" != "--no-compositor" ] && [ ! -S "$SOCK" ]; then
    if [ -x "$BIN/iosc" ]; then
        log "starting iosc..."
        "$BIN/iosc" >"$JB/tmp/iosc.log" 2>&1 &
    else
        log "ERROR: no wayland socket at $SOCK and $BIN/iosc not found"
        log "start the compositor first (wayland/run-iosc.sh)"; exit 1
    fi
    # wait for the socket (iosc creates it before first present)
    n=0
    while [ ! -S "$SOCK" ] && [ $n -lt 50 ]; do sleep 0.2; n=$((n+1)); done
    [ -S "$SOCK" ] || { log "ERROR: iosc did not create $SOCK"; exit 1; }
    log "iosc up ($SOCK). Open the Xios app to see the display."
fi

# -- 2 + 3. shell clients ------------------------------------------------------
start() {  # start <name> (skips if already running)
    if pgrep -x "$1" >/dev/null 2>&1; then log "$1 already running"; return; fi
    if [ -x "$BIN/$1" ]; then "$BIN/$1" >"$JB/tmp/$1.log" 2>&1 & log "$1 started";
    else log "WARNING: $BIN/$1 not found (skipped)"; fi
}
start ioscbg
sleep 0.3          # let the wallpaper map first (clean first frame)
start ioscpanel

log "shell up. ⊞ (panel, far left) opens the overview; status cluster opens quick settings."
