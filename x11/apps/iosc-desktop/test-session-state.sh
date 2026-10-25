#!/usr/bin/env bash
# Regression coverage for the display-status/app-launch separation and for the
# installed capability-profile layout.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_TMP="$(mktemp -d)"
socket_pid=
cleanup() {
    [ -z "$socket_pid" ] || kill "$socket_pid" 2>/dev/null || true
    [ -z "$socket_pid" ] || wait "$socket_pid" 2>/dev/null || true
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

installed="$TEST_TMP/var/jb/libexec/xios-session"
mkdir -p "$installed"
cp "$HERE/xios-capability-profiles.sh" "$installed/"
profile_output="$(
    env -u XIOS_PREFIX \
        "$installed/xios-capability-profiles.sh" --env plasma-egl 2>&1
)"
case "$profile_output" in
    *linux-build/target-lib.sh*|*xios_load_target:\ command\ not\ found*)
        echo "installed capability profile tried to load build-tree state" >&2
        exit 1
        ;;
esac
printf '%s\n' "$profile_output" |
    grep -q "^export DYLD_LIBRARY_PATH='$TEST_TMP/var/jb/usr/lib:"

export XS_JB=
export XS_TMP="$TEST_TMP/runtime"
export XS_VAR="$TEST_TMP/runtime/var"
export XS_STATUS="$XS_TMP/xios-session-status.json"
export XS_APP_STATUS="$XS_TMP/xios-app-launch-status.json"
export XS_ACTIVE="$XS_TMP/xios-active-session"
export XS_LOG="$XS_TMP/xios-session.log"
export XS_BASH=/bin/bash
export XS_DBUS_RUN=/usr/bin/env
export XS_DBUS_DAEMON=/nonexistent
export XS_UIOPEN=/usr/bin/true
mkdir -p "$XS_TMP" "$XS_VAR/root"

# shellcheck source=./xios-session-lib.sh
. "$HERE/xios-session-lib.sh"
xs_foreground_xios() { :; }
xs_session_bus_address() { return 1; }

printf '%s\n' kde >"$XS_ACTIVE"
printf '%s\n' '{"preset":"kde","state":"up","message":"ready"}' >"$XS_STATUS"
desktop_status="$(cat "$XS_STATUS")"

if xios_session_app true 2>/dev/null; then
    echo "app launch unexpectedly succeeded without a compositor" >&2
    exit 1
fi
[ "$(cat "$XS_STATUS")" = "$desktop_status" ]
grep -q '"state":"error"' "$XS_APP_STATUS"

runtime="$(xs_kde_runtime_dir)"
mkdir -p "$runtime"
/usr/bin/python3 - "$runtime/$XS_KWIN_SOCKET" <<'PY' &
import socket
import sys
import time

server = socket.socket(socket.AF_UNIX)
server.bind(sys.argv[1])
server.listen(1)
time.sleep(10)
PY
socket_pid=$!
for _ in $(seq 1 30); do
    [ -S "$runtime/$XS_KWIN_SOCKET" ] && break
    sleep 0.1
done
[ -S "$runtime/$XS_KWIN_SOCKET" ]

xios_session_app true >/dev/null
[ "$(cat "$XS_STATUS")" = "$desktop_status" ]
grep -q '"state":"submitted"' "$XS_APP_STATUS"
grep -q '"owner":"kde"' "$XS_APP_STATUS"

echo "session-state: installed profile and additive app status checks passed"

# ---------------------------------------------------------------------------
# stale display-slot sweep
#
# Regression: the sweeper used to skip any slot whose socket or config file
# still existed, which is exactly the state a session that died dirty leaves
# behind. Slots that crashed/were jetsammed/survived a reboot therefore piled
# up in $XS_TMP forever, while only the already-clean slots were swept.
# ---------------------------------------------------------------------------
mkdir -p "$XS_SLOT_REGISTRY_DIR"

stale_slot=deadslot
printf '{"wayland":"wayland-%s","json":"%s/xios-%s.json"}\n' \
    "$stale_slot" "$XS_TMP" "$stale_slot" \
    >"$XS_SLOT_REGISTRY_DIR/$stale_slot.json"
# The full dirty footprint: rendezvous socket + lock, config, every sidecar
# socket, the status file, and a log that must SURVIVE the sweep.
: >"$XS_TMP/wayland-$stale_slot"
: >"$XS_TMP/wayland-$stale_slot.lock"
: >"$XS_TMP/xios-$stale_slot.json"
: >"$XS_TMP/iosc-$stale_slot-ddx.sock"
: >"$XS_TMP/iosc-$stale_slot-input.sock"
: >"$XS_TMP/iosc-$stale_slot-clipboard.sock"
: >"$XS_TMP/iosc-$stale_slot-wm.sock"
: >"$XS_TMP/mutter-$stale_slot-ddx.sock"
: >"$XS_TMP/xios-session-$stale_slot.json"
: >"$XS_TMP/iosc-$stale_slot.log"

# A slot with a live process must be left completely alone, even though its
# files look identical to the stale one's.
live_slot=liveslot
printf '{"wayland":"wayland-%s","json":"%s/xios-%s.json"}\n' \
    "$live_slot" "$XS_TMP" "$live_slot" \
    >"$XS_SLOT_REGISTRY_DIR/$live_slot.json"
: >"$XS_TMP/wayland-$live_slot"
: >"$XS_TMP/xios-$live_slot.json"
/usr/bin/python3 -c 'import time; time.sleep(30)' "wayland-$live_slot" &
live_pid=$!
trap 'kill "$live_pid" 2>/dev/null || true; cleanup' EXIT
for _ in $(seq 1 30); do
    xs_slot_has_live_process "$live_slot" && break
    sleep 0.1
done
xs_slot_has_live_process "$live_slot" || {
    echo "test setup failed: live slot process never appeared in ps" >&2
    exit 1
}

xs_sweep_stale_slot_registry

for leftover in \
    "$XS_SLOT_REGISTRY_DIR/$stale_slot.json" \
    "$XS_TMP/wayland-$stale_slot" \
    "$XS_TMP/wayland-$stale_slot.lock" \
    "$XS_TMP/xios-$stale_slot.json" \
    "$XS_TMP/iosc-$stale_slot-ddx.sock" \
    "$XS_TMP/iosc-$stale_slot-input.sock" \
    "$XS_TMP/iosc-$stale_slot-clipboard.sock" \
    "$XS_TMP/iosc-$stale_slot-wm.sock" \
    "$XS_TMP/mutter-$stale_slot-ddx.sock" \
    "$XS_TMP/xios-session-$stale_slot.json"; do
    if [ -e "$leftover" ]; then
        echo "sweep left stale slot state behind: $leftover" >&2
        exit 1
    fi
done

[ -e "$XS_TMP/iosc-$stale_slot.log" ] || {
    echo "sweep deleted the stale slot's log (needed for post-mortem)" >&2
    exit 1
}

for kept in \
    "$XS_SLOT_REGISTRY_DIR/$live_slot.json" \
    "$XS_TMP/wayland-$live_slot" \
    "$XS_TMP/xios-$live_slot.json"; do
    [ -e "$kept" ] || {
        echo "sweep removed state belonging to a LIVE slot: $kept" >&2
        exit 1
    }
done

kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true
live_pid=
trap cleanup EXIT

echo "session-state: stale display-slot sweep checks passed"

# ---------------------------------------------------------------------------
# bring-up override, session-lock handoff, and GNOME liveness
# ---------------------------------------------------------------------------
# XIOS_SESSION_BRINGUP_DIR must resolve to the script inside it. It used to
# resolve to the bare directory: `local name=$1 o=$DIR/$name` expands $name
# before the first assignment takes effect.
bringup="$TEST_TMP/bringup"
mkdir -p "$bringup"
: >"$bringup/run-shell.sh"
found="$(XIOS_SESSION_BRINGUP_DIR="$bringup" xs_find_bringup run-shell.sh)"
[ "$found" = "$bringup/run-shell.sh" ] || {
    echo "XIOS_SESSION_BRINGUP_DIR override resolved to '$found'" >&2
    exit 1
}

# A lock dir whose owner has not written its pid yet is a lock being taken,
# not a stale one; only a pid file that stays missing means a dead owner.
mkdir -p "$XS_LOCK_DIR"
XS_LOCK_NOPID_SEEN=0
if xs_session_lock_is_stale; then
    echo "a just-taken session lock (no pid yet) was judged stale" >&2
    exit 1
fi
if xs_session_lock_is_stale; then
    echo "a pid-less session lock was judged stale on the 2nd sighting" >&2
    exit 1
fi
xs_session_lock_is_stale || { echo "a pid-less lock was never judged stale" >&2; exit 1; }
printf '%s\n' "$$" >"$XS_LOCK_DIR/pid"
date '+%s' >"$XS_LOCK_DIR/started"
if xs_session_lock_is_stale; then
    echo "a live lock owner was judged stale" >&2
    exit 1
fi
rm -rf "$XS_LOCK_DIR"

# Another desktop's GNOME must not keep this session's dead GNOME "alive":
# with a recorded pgid, only that process group counts.
perl -e 'setpgrp(0,0); exec { "sleep" } @ARGV' -- \
    "/usr/bin/gnome-session --builtin --session=xios" 30 >/dev/null 2>&1 </dev/null &
other_gnome=$!
trap 'kill "$other_gnome" 2>/dev/null || true; cleanup' EXIT
for _ in $(seq 1 30); do
    xios_session_process_running "gnome-session.*--session=xios" && break
    sleep 0.1
done
(
    XS_SLOT=gslot
    # A process group nothing lives in.
    printf '%s\n' 999999 >"$XS_TMP/xios-gnome-gslot.pgid"
    if xs_gnome_session_alive; then
        echo "a dead slot GNOME looked alive because another GNOME runs" >&2
        exit 1
    fi
    ps -p "$other_gnome" -o pgid= | tr -cd '0-9' >"$XS_TMP/xios-gnome-gslot.pgid"
    xs_gnome_session_alive || { echo "a live GNOME process group was not seen" >&2; exit 1; }
)
kill "$other_gnome" 2>/dev/null || true
wait "$other_gnome" 2>/dev/null || true
trap cleanup EXIT

echo "session-state: bring-up override, lock handoff and GNOME liveness checks passed"
