#!/usr/bin/env bash
# Regression coverage for desktop coexistence: a non-slot teardown, the stale-slot
# sweep and a slot stop must each touch exactly the processes they own.
#
# Everything runs against fake processes (sleep with a rewritten argv0) in a
# scratch XS_TMP, and the teardown pattern is replaced with a private token, so
# running this on a developer machine never signals a real process.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_TMP="$(mktemp -d)"
FAKE_PIDS=()
cleanup() {
    local p
    for p in ${FAKE_PIDS[@]+"${FAKE_PIDS[@]}"}; do kill -9 "$p" 2>/dev/null || true; done
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
alive() { kill -0 "$1" 2>/dev/null; }

# fake <argv0 incl. needles> [own-pgid]  -> pid in $FAKE (not via $(...): the
# background child would hold the substitution's pipe open for its whole life)
FAKE=
fake() {
    # Every fake leads its own process group, like a real desktop started by
    # ioscd or xios-setsid.
    perl -e 'setpgrp(0,0); exec { "sleep" } @ARGV' -- "$1" 300 >/dev/null 2>&1 </dev/null &
    FAKE=$!
    FAKE_PIDS+=("$FAKE")
}

export XS_JB=
export XS_TMP="$TEST_TMP/runtime"
export XS_VAR="$TEST_TMP/runtime/var"
export XS_LOG="$XS_TMP/xios-session.log"
export XS_BASH=/bin/bash
export XS_UIOPEN=/usr/bin/true
export XIOS_SESSION_SWEEP_SLOTS=1
mkdir -p "$XS_TMP" "$XS_VAR/root"

# ---- exact slot needles: "kde" must never match "kde-2" or "kde2" -------------
(
    unset XIOS_SESSION_SLOT
    # shellcheck source=./xios-session-lib.sh
    . "$HERE/xios-session-lib.sh"
    re_kde="$(xs_slot_regex kde)"
    m() { printf '%s\n' "$1" | grep -Eq "$re_kde"; }
    m 'iosc -s wayland-kde -ddx-sock /t/iosc-kde-ddx.sock' || fail "kde needle misses its own iosc"
    m 'kwin_wayland --socket kwin-kde' || fail "kde needle misses its kwin"
    m 'mutter --wayland-display wayland-kde' || fail "kde needle misses mutter"
    if m 'iosc -s wayland-kde-2 -ddx-sock /t/iosc-kde-2-ddx.sock'; then fail "kde matched kde-2"; fi
    if m 'kwin_wayland --socket kwin-kde2'; then fail "kde matched kde2"; fi
    if m 'iosc -s wayland-0 -ddx-sock /t/iosc-ddx.sock'; then fail "kde matched the global session"; fi
    re_dot="$(xs_slot_regex a.b)"
    if printf '%s\n' 'iosc -s wayland-aXb' | grep -Eq "$re_dot"; then fail "slot dot is not escaped"; fi
) || exit 1
echo "ok: slot needles are exact"

# ---- fixtures ------------------------------------------------------------------
fake "XIOSFAKE-global iosc -s wayland-0 -ddx-sock $XS_TMP/iosc-ddx.sock"; G=$FAKE
fake "XIOSFAKE-alpha iosc -s wayland-alpha -ddx-sock $XS_TMP/iosc-alpha-ddx.sock"; A=$FAKE
fake "XIOSFAKE-beta iosc -s wayland-beta -ddx-sock $XS_TMP/iosc-beta-ddx.sock"; B=$FAKE
# A GNOME-like slot: argv names no slot at all, only its recorded process group
# says whose it is (this is exactly gnome-shell under xios-setsid).
fake "XIOSFAKE-gnome /usr/bin/gnome-shell"; N=$FAKE
sleep 0.5
NPGID="$(ps -p "$N" -o pgid= | tr -d ' ')"
[ "$NPGID" = "$N" ] || fail "fixture: gnome-like process is not its own group leader ($NPGID vs $N)"

mkdir -p "$XS_TMP/xios-displays.d"
for s in alpha beta gnomeslot; do
    printf '{"slot":"%s","preset":"x","state":"up","wayland":"wayland-%s","json":"%s/xios-%s.json"}\n' \
        "$s" "$s" "$XS_TMP" "$s" >"$XS_TMP/xios-displays.d/$s.json"
    : >"$XS_TMP/wayland-$s"
    : >"$XS_TMP/xios-$s.json"
done
printf '%s\t%s\t%s\t%s\n' "$NPGID" gnome gnomeslot 2026-10-06T00:00:00 >"$XS_TMP/xios-session.pgids"

run_lib() {  # run_lib <slot-or-empty> <function...>
    local slot="$1"; shift
    (
        if [ -n "$slot" ]; then export XIOS_SESSION_SLOT="$slot"; else unset XIOS_SESSION_SLOT; fi
        # shellcheck source=./xios-session-lib.sh
        . "$HERE/xios-session-lib.sh"
        xs_kill_pattern='XIOSFAKE-[a-z]+'
        xs_shared_kill_pattern='XIOSFAKE-shared-never'
        "$@"
    )
}

# ---- non-slot teardown: kills the global fake, spares every slot ---------------
run_lib "" xios_session_teardown "test" 0 0 >/dev/null 2>&1
sleep 0.3
alive "$G" && fail "global session fake survived its own teardown"
alive "$A" || fail "non-slot teardown killed slot alpha (argv needle)"
alive "$B" || fail "non-slot teardown killed slot beta (argv needle)"
alive "$N" || fail "non-slot teardown killed the GNOME-like slot (recorded pgid)"
echo "ok: non-slot teardown spares every slot"

# ---- stale sweep: only slots with NO live process go ---------------------------
run_lib "" xs_sweep_stale_slot_registry >/dev/null 2>&1
[ -f "$XS_TMP/xios-displays.d/alpha.json" ] || fail "sweep dropped live slot alpha"
[ -f "$XS_TMP/xios-displays.d/beta.json" ] || fail "sweep dropped live slot beta"
[ -f "$XS_TMP/xios-displays.d/gnomeslot.json" ] || fail "sweep dropped the live GNOME-like slot"
kill -9 "$B"; sleep 0.3
run_lib "" xs_sweep_stale_slot_registry >/dev/null 2>&1
[ -f "$XS_TMP/xios-displays.d/beta.json" ] && fail "sweep kept dead slot beta"
[ -f "$XS_TMP/xios-displays.d/alpha.json" ] || fail "sweep dropped alpha while sweeping beta"
[ -f "$XS_TMP/xios-displays.d/gnomeslot.json" ] || fail "sweep dropped gnomeslot while sweeping beta"
echo "ok: sweep keeps live slots (including pgid-only GNOME), drops dead ones"

# ---- slot stop: only that slot --------------------------------------------------
fake "XIOSFAKE-alpha2 iosc -s wayland-alpha-2 -ddx-sock $XS_TMP/iosc-alpha-2-ddx.sock"; A2=$FAKE
sleep 0.3
run_lib alpha xios_session_stop >/dev/null 2>&1
sleep 0.3
alive "$A" && fail "slot stop left alpha running"
alive "$A2" || fail "stopping slot alpha killed slot alpha-2"
alive "$N" || fail "stopping slot alpha killed the GNOME-like slot"
echo "ok: slot stop is scoped to its slot"

# ---- GNOME-like slot stop reaps by recorded pgid --------------------------------
run_lib gnomeslot xios_session_stop >/dev/null 2>&1
sleep 0.3
alive "$N" && fail "slot stop did not reap the GNOME-like slot's process group"
alive "$A2" || fail "stopping the GNOME-like slot killed alpha-2"
echo "ok: slot stop reaps a pgid-only slot"

echo "PASS"
