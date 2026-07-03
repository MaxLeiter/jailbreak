#!/usr/bin/env bash
# iosc-capture.sh — launch a Wayland client in the iosc compositor, screenshot it
# with grim, capture its stderr, and diagnose why it did (or did not) map a window.
#
# Runs ON-DEVICE, inside the jailbreak /var/jb environment. A mac-side debug skill
# scp's this over, runs it via ssh, then pulls back the PNG + log. It is also fine
# to run by hand over ssh.
#
#   iosc-capture.sh <name> <command> [args...]
#
# Examples:
#   iosc-capture.sh hitori  hitori
#   iosc-capture.sh zathura zathura /var/jb/tmp/doc.pdf
#   iosc-capture.sh mpv     mpv-iosc /var/jb/tmp/clip.mp4
#   iosc-capture.sh foot    foot --log-level=debug
#
# Env overrides:
#   WAYLAND_DISPLAY   (default /var/jb/tmp/wayland-0)
#   XDG_RUNTIME_DIR   (default /var/jb/tmp)
#   IOSC_CAP_WAIT     seconds to let the client map before capture (default 4)
#   IOSC_CAP_OUT      output dir for PNG + log (default $XDG_RUNTIME_DIR)
#
# Exit: 0 = client still alive at capture (likely mapped). 1 = client exited early
# (launch failure; see the matched signature). 2 = environment/precondition error.

set -u

name="${1:-}"; shift || true
if [ -z "$name" ] || [ "$#" -eq 0 ]; then
    echo "usage: iosc-capture.sh <name> <command> [args...]" >&2
    exit 2
fi

export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-/var/jb/tmp/wayland-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/var/jb/tmp}"
WAIT="${IOSC_CAP_WAIT:-4}"
OUT="${IOSC_CAP_OUT:-$XDG_RUNTIME_DIR}"
PNG="$OUT/cap-$name.png"
LOG="$OUT/cap-$name.log"
GERR="$OUT/cap-$name.grim.err"

sz() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }
say() { printf '%s\n' "$*"; }

# ---- preconditions ---------------------------------------------------------
if [ ! -S "$WAYLAND_DISPLAY" ] && [ ! -e "$WAYLAND_DISPLAY" ]; then
    say "PRECONDITION FAIL: no wayland socket at $WAYLAND_DISPLAY"
    say "  -> is iosc running, and in the CLASSIC desktop (not -native)?"
    say "     ls -l $XDG_RUNTIME_DIR/wayland-*"
    exit 2
fi
have_grim=1; command -v grim >/dev/null 2>&1 || have_grim=0

# ---- launch the client -----------------------------------------------------
say "=== iosc-capture: $name ==="
say "cmd: $*"
say "env: WAYLAND_DISPLAY=$WAYLAND_DISPLAY XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
: > "$LOG"
# setsid isn't present on iOS; detach if we have it, otherwise plain background.
if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >>"$LOG" 2>&1 &
else
    "$@" >>"$LOG" 2>&1 &
fi
pid=$!
# poll up to WAIT seconds; note whether it dies early
alive=1
for _ in $(seq 1 "$WAIT"); do
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then alive=0; break; fi
done

# ---- capture ---------------------------------------------------------------
gsz=0
if [ "$have_grim" = 1 ]; then
    grim "$PNG" 2>"$GERR" && gsz="$(sz "$PNG")"
    if [ "$gsz" -gt 0 ]; then
        say "grim: wrote $PNG ($gsz bytes)"
    else
        say "grim: FAILED -> $(head -c 200 "$GERR" 2>/dev/null)"
        say "  (grim returns blank in -native mode; classic desktop only)"
    fi
else
    say "grim: not installed (skip screenshot). Pixel-truth fallback: IOSC_PROBE=1 on the compositor."
fi

# ---- verdict ---------------------------------------------------------------
rc=0
if [ "$alive" = 1 ]; then
    say "client: STILL RUNNING after ${WAIT}s (pid $pid) -> likely mapped a window"
    kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
else
    wait "$pid" 2>/dev/null; ec=$?
    say "client: EXITED early (code $ec) -> launch failure, see signature below"
    rc=1
fi

# ---- signature match (root-cause the stderr) -------------------------------
# Patterns + fixes distilled from the 2026-07 iosc app-launch diagnosis.
say "--- log tail ($LOG) ---"
tail -n 20 "$LOG" 2>/dev/null
say "--- diagnosis ---"
match() { grep -Eiq "$1" "$LOG" 2>/dev/null; }
hit=0
if match "settings schema .* (is )?not installed|g_settings_new"; then
    say "SIGNATURE: GSettings schema not compiled/installed."
    say "  FIX: ship the app's gschema + a postinst that runs glib-compile-schemas"
    say "       (GSETTINGS_BACKEND=memory does NOT help — schema lookup is separate)."
    hit=1
fi
if match "cannot open display|unable to init server|failed to open display|gdk_wayland|no available.*backend"; then
    say "SIGNATURE: GDK backend mismatch (GTK built without the Wayland backend)."
    say "  FIX: install the multi-backend libgtk-3-0 (>=3.24.38+ios1); or run under"
    say "       Xwayland with GDK_BACKEND=x11 DISPLAY=:0."
    hit=1
fi
if match "failed to initialize any suitable vo|libegl|eglinitialize|egl.*fail|wl_drm|dmabuf|gpu context"; then
    say "SIGNATURE: GPU/EGL path — client's libEGL is not the iosc shim, or VO init failed."
    say "  FIX: ensure /var/jb/lib/angle/libEGL.dylib is the shim"
    say "       (nm -U /var/jb/lib/angle/libEGL.dylib | grep iosc_iosurface); install angle (>=es3-3)."
    say "       For mpv use the mpv-iosc wrapper (--gpu-context=wayland)."
    hit=1
fi
if match "posix_openpt|pseudo.?terminal|/dev/ptmx|grantpt|unlockpt|ptsname|openpty"; then
    say "SIGNATURE: PTY allocation failed (terminal apps)."
    say "  FIX: needs a working /dev/ptmx path in the sandbox / a pty-open fallback shim."
    hit=1
fi
if match "timerfd|signalfd|failed to create fd manager|epoll"; then
    say "SIGNATURE: event-loop fd primitive missing (epoll-shim gap: timerfd/signalfd)."
    say "  FIX: extend epoll-shim to provide the missing fd primitive."
    hit=1
fi
if match "failed to load font|no fonts|cannot load font|fontconfig.*error"; then
    say "SIGNATURE: no usable font (fontconfig has no monospace/default face)."
    say "  FIX: install a font + a fontconfig alias for the family the app requests."
    hit=1
fi
if match "cannot connect to wayland|wl_display_connect|failed to connect to display"; then
    say "SIGNATURE: could not connect to the compositor."
    say "  FIX: iosc not running, wrong WAYLAND_DISPLAY, or -native mode. Check the socket."
    hit=1
fi
[ "$hit" = 0 ] && [ "$rc" = 1 ] && say "SIGNATURE: unrecognized. Inspect $LOG in full."
[ "$hit" = 0 ] && [ "$rc" = 0 ] && say "(no failure signature; client appears healthy)"

say "--- artifacts ---"
say "  screenshot: $PNG"
say "  stderr log: $LOG"
exit "$rc"
