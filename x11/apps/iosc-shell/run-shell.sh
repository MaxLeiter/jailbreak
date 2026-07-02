#!/bin/sh
#
# run-shell.sh — start the iosc desktop shell ON DEVICE.
#
# Brings up the full lightweight desktop: the iosc compositor, then the shell
# layer-shell clients (wallpaper, status bar, dock). The overview is spawned on
# demand by the dock's apps button / Control Center "Overview" action.
#
#   1. iosc        the compositor (skipped if a wayland-0 socket already lives —
#                  e.g. wayland/run-iosc.sh or ioscd already started it; open the
#                  Xios app to see the output either way)
#   2. ioscbg      wallpaper (background layer)
#   3. ioscbar     slim status bar + Control Center (top layer)
#   4. ioscdock    floating launcher/task dock (bottom layer)
#
# Usage:  run-shell.sh [--no-compositor]
# Env:    IOSC_PANEL_SCALE (default 2), IOSC_WALLPAPER, IOSC_SHELL_ICONS,
#         IOSC_PANEL_OPACITY (once iosc blends layer surfaces)
#
# This is the future `xios-iosc` flavor: iosc + these clients are the whole
# desktop — no Mutter, no JS, pure C/Wayland. Package: package-shell.sh.
set -e

detect_jbroot() {
    if [ -n "${IOSC_JBROOT:-}" ]; then printf '%s\n' "${IOSC_JBROOT%/}"; return; fi
    if [ -n "${JBROOT:-}" ]; then printf '%s\n' "${JBROOT%/}"; return; fi
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
BIN=$(jb_path /usr/local/bin)
TMP=$(jb_path /tmp)
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-$TMP}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export IOSC_PANEL_SCALE="${IOSC_PANEL_SCALE:-2}"
# Logical desktop the shell designs its elements for. iosc renders a 2x-oversized
# output IOSurface (1440x1080 -> 2880x2160) that the Xios app supersamples down to
# the 2160x1620 panel = ~1.5 effective scale (Max-approved). Override to retune.
export IOSC_LOGICAL="${IOSC_LOGICAL:-1440x1080}"
# Input tracing to $XDG_RUNTIME_DIR/{ioscbar,ioscdock}.log — default ON while the shell-tap
# bug is being hunted (Max: panel dead to taps, 2026-07-01). Flip to 0 after.
export IOSC_SHELL_DEBUG="${IOSC_SHELL_DEBUG:-1}"

SOCK="$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"
log() { echo "run-shell: $*" >&2; }

# -- 1. compositor -----------------------------------------------------------
if [ "${1:-}" != "--no-compositor" ] && [ ! -S "$SOCK" ]; then
    if [ -x "$BIN/iosc" ]; then
        log "starting iosc (logical $IOSC_LOGICAL)..."
        "$BIN/iosc" -logical "$IOSC_LOGICAL" >"$TMP/iosc.log" 2>&1 &
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

# -- 2 + 3 + 4. shell clients -------------------------------------------------
start() {  # start <name> (skips if already running)
    if pgrep -x "$1" >/dev/null 2>&1; then log "$1 already running"; return; fi
    if [ -x "$BIN/$1" ]; then "$BIN/$1" >"$TMP/$1.log" 2>&1 & log "$1 started";
    else log "WARNING: $BIN/$1 not found (skipped)"; fi
}
start ioscbg
sleep 0.3          # let the wallpaper map first (clean first frame)
if [ -x "$BIN/ioscbar" ] && [ -x "$BIN/ioscdock" ]; then
    start ioscbar
    start ioscdock
else
    log "split shell clients missing; falling back to legacy ioscpanel"
    start ioscpanel
fi

log "shell up. Dock apps button opens overview; status cluster opens Control Center."
