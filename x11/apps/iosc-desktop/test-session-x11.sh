#!/usr/bin/env bash
# Regression coverage for X11 under an iosc desktop: the iosc preset turns on
# iosc's rootless Xwayland only when Xwayland is installed, and app launches get
# the DISPLAY iosc published (per slot), never a stale one.
#
# Runs against a scratch XS_TMP with fake sockets and a fake run-shell.sh; it
# starts no compositor and signals no process.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_TMP="$(mktemp -d)"
SOCK_PIDS=()
cleanup() {
    local p
    for p in ${SOCK_PIDS[@]+"${SOCK_PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

listen() {  # listen <unix-socket-path>: a live listener, like a real server's
    /usr/bin/python3 - "$1" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(1)
time.sleep(30)
PY
    SOCK_PIDS+=("$!")
    local _
    for _ in $(seq 1 50); do [ -S "$1" ] && return 0; sleep 0.1; done
    fail "listener $1 never appeared"
}

export XS_JB=
export XS_TMP="$TEST_TMP/rt"
export XS_VAR="$TEST_TMP/rt/var"
export XS_LOG="$XS_TMP/xios-session.log"
export XS_UIOPEN=/usr/bin/true
export XS_DBUS_RUN=/usr/bin/env
export XS_DBUS_DAEMON=/nonexistent
export XS_PREFIX="$TEST_TMP/usr"
export XS_X11_UNIX_DIR="$TEST_TMP/x11"
export CAPTURE="$TEST_TMP/app.env"
mkdir -p "$XS_TMP" "$XS_VAR/root" "$XS_X11_UNIX_DIR" "$XS_PREFIX/bin" "$XS_TMP/xios-status.d"
unset IOSC_XWAYLAND IOSC_XWAYLAND_BIN DISPLAY XIOS_SESSION_SLOT XIOS_STATUS_DIR

# The "app" shell: record the environment the client would run with.
fakebash="$TEST_TMP/fakebash"
printf '#!/bin/sh\nenv >"$CAPTURE.tmp" && mv "$CAPTURE.tmp" "$CAPTURE"\n' >"$fakebash"
chmod +x "$fakebash"
export XS_BASH="$fakebash"

launch_env() {  # launch_env <app>: run xios_session_app, print the client's env
    rm -f "$CAPTURE"
    xios_session_app "$1" >/dev/null 2>&1 || fail "app launch failed"
    local _
    for _ in $(seq 1 50); do [ -s "$CAPTURE" ] && break; sleep 0.1; done
    [ -s "$CAPTURE" ] || fail "client never ran"
    cat "$CAPTURE"
}

(
    # shellcheck source=./xios-session-lib.sh
    . "$HERE/xios-session-lib.sh"
    xs_foreground_xios() { :; }
    xs_session_bus_address() { return 1; }

    # --- iosc preset: IOSC_XWAYLAND follows the installed Xwayland ----------
    bringup="$TEST_TMP/run-shell.sh"
    printf '#!/bin/sh\nenv >"%s"\n' "$TEST_TMP/iosc.env" >"$bringup"
    xs_prepare_display_session() { :; }
    xs_find_bringup() { printf '%s\n' "$bringup"; }
    xs_record_slot_process_pgroups() { :; }
    xs_wait_socket() { return 0; }
    xs_fix_ddx_perms() { :; }
    xs_ensure_xios() { :; }

    ( xios_session_iosc >/dev/null 2>&1 ) || fail "iosc preset failed (no Xwayland)"
    grep -q '^IOSC_XWAYLAND=' "$TEST_TMP/iosc.env" && fail "IOSC_XWAYLAND set without Xwayland"

    printf '#!/bin/sh\n' >"$XS_PREFIX/bin/Xwayland"; chmod +x "$XS_PREFIX/bin/Xwayland"
    ( xios_session_iosc >/dev/null 2>&1 ) || fail "iosc preset failed (Xwayland)"
    grep -qx 'IOSC_XWAYLAND=1' "$TEST_TMP/iosc.env" || fail "IOSC_XWAYLAND not exported"
    grep -qx "IOSC_XWAYLAND_BIN=$XS_PREFIX/bin/Xwayland" "$TEST_TMP/iosc.env" \
        || fail "IOSC_XWAYLAND_BIN not the installed Xwayland"
    ( IOSC_XWAYLAND=0 xios_session_iosc >/dev/null 2>&1 ) || fail "iosc preset failed (opt-out)"
    grep -qx 'IOSC_XWAYLAND=0' "$TEST_TMP/iosc.env" || fail "IOSC_XWAYLAND=0 opt-out overridden"

    # --- app launches: DISPLAY only from a live published display ----------
    printf 'iosc\n' >"$XS_ACTIVE"
    listen "$XS_WAYLAND_SOCK"

    env_out="$(launch_env xterm)"
    printf '%s\n' "$env_out" | grep -q '^DISPLAY=' && fail "DISPLAY set with no x11-display published"

    printf 'pacing\tevent-loop\nx11-display\t:3\n' >"$XS_TMP/xios-status.d/iosc.status"
    env_out="$(launch_env xterm)"
    printf '%s\n' "$env_out" | grep -q '^DISPLAY=' && fail "DISPLAY set for a dead X server (no socket)"

    listen "$XS_X11_UNIX_DIR/X3"
    env_out="$(launch_env xterm)"
    printf '%s\n' "$env_out" | grep -qx 'DISPLAY=:3' || fail "DISPLAY=:3 not passed to the app"
    printf '%s\n' "$env_out" | grep -qx 'GDK_BACKEND=wayland,x11' || fail "GDK_BACKEND keeps no X11 fallback"
    printf '%s\n' "$env_out" | grep -qx "WAYLAND_DISPLAY=$XS_WAYLAND_SOCK" || fail "WAYLAND_DISPLAY changed"

    printf 'x11-display\tnone\n' >"$XS_TMP/xios-status.d/iosc.status"
    env_out="$(launch_env xterm)"
    printf '%s\n' "$env_out" | grep -q '^DISPLAY=' && fail "DISPLAY set after iosc retracted it"

    # Another desktop owns the session: iosc's display is not its business.
    printf 'x11-display\t:3\n' >"$XS_TMP/xios-status.d/iosc.status"
    printf 'mutter\n' >"$XS_ACTIVE"
    env_out="$(launch_env xterm)"
    printf '%s\n' "$env_out" | grep -q '^DISPLAY=' && fail "iosc DISPLAY leaked into a mutter session"
    exit 0
) || exit 1

# --- slots read their own iosc's sidecar --------------------------------------
(
    export XIOS_SESSION_SLOT=side
    # shellcheck source=./xios-session-lib.sh
    . "$HERE/xios-session-lib.sh"
    printf 'x11-display\t:3\n' >"$XS_TMP/xios-status.d/iosc.status"
    printf 'x11-display\t:5\n' >"$XS_TMP/xios-status.d/iosc-side.status"
    xs_iosc_x11_display >/dev/null && fail "slot believed :5 with no X5 socket"
    listen "$XS_X11_UNIX_DIR/X5"
    [ "$(xs_iosc_x11_display)" = ":5" ] || fail "slot did not read iosc-side.status"
    printf 'x11-display\t:5x\n' >"$XS_TMP/xios-status.d/iosc-side.status"
    xs_iosc_x11_display >/dev/null && fail "malformed display accepted"
    exit 0
) || exit 1

echo "session-x11: Xwayland opt-in and per-slot DISPLAY checks passed"
