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
