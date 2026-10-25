#!/usr/bin/env bash
# Regression coverage for the preset preflight: picking a flavor that is not
# installed must be refused BEFORE the running desktop is torn down.
#
# The scenario is the one that bit a KDE user: a live KDE desktop, xios-session-stubs
# installed (so launch-gnome-session.sh resolves) but no gnome-shell, and a tap on
# GNOME. It runs the real CLI against a scratch rootless prefix and scratch XS_TMP,
# with fake KDE processes (sleep with a rewritten argv0). The teardown pattern is
# replaced with a private token, so even a regression never signals a real process.
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

fail() { echo "FAIL: $*" >&2; [ -f "${XS_LOG:-}" ] && sed 's/^/  log| /' "$XS_LOG" >&2; exit 1; }
alive() { kill -0 "$1" 2>/dev/null; }
jget() { sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" "$1" | head -n 1; }

FAKE=
fake() {  # fake <argv0> -> pid in $FAKE, its own process-group leader
    perl -e 'setpgrp(0,0); exec { "sleep" } @ARGV' -- "$1" 300 >/dev/null 2>&1 </dev/null &
    FAKE=$!
    FAKE_PIDS+=("$FAKE")
}
exe() {  # exe <path>: an installed executable stand-in
    mkdir -p "$(dirname "$1")"
    printf '#!/bin/sh\nexit 0\n' >"$1"
    chmod 0755 "$1"
}

# ---- a scratch rootless install: base runtime + KDE, no GNOME, no mutter --------
export XS_JB="$TEST_TMP/jb"
export XS_TMP="$TEST_TMP/runtime"
export XS_VAR="$TEST_TMP/runtime/var"
export XS_LOG="$XS_TMP/xios-session.log"
export XS_BASH=/bin/bash
export XS_UIOPEN=/usr/bin/true
export XIOS_SESSION_SETTLE=0
export XIOS_IOS_APP_ENTRIES=0
export XIOS_SESSION_OWN_PGROUP=1     # skip the CLI's xios-setsid re-exec
unset XIOS_SESSION_SLOT MUTTER SHELL_BIN IOSC_BIN KWIN_BIN PLASMA_BIN XIOS_SESSION_BRINGUP_DIR || true
PFX="$XS_JB/usr"
LIBX="$XS_JB/libexec/xios-session"
mkdir -p "$XS_TMP" "$XS_VAR/root" "$LIBX"

# xios-session's own libexec copies of the bring-up scripts (always shipped)
exe "$LIBX/run-shell.sh"
exe "$LIBX/run-mutter.sh"
exe "$LIBX/run-kde-plasma.sh"
# xios-session-stubs (base runtime): the GNOME launcher and xios-setsid
exe "$PFX/bin/launch-gnome-session.sh"
exe "$PFX/libexec/xios-setsid"
# xios-core + xios-kde
exe "$PFX/local/bin/iosc"
exe "$XS_JB/Applications/KDE/kwin_wayland.app/kwin_wayland"
exe "$XS_JB/Applications/KDE/plasmashell.app/plasmashell"

# The CLI loads this wrapper: the real lib with the teardown patterns pointed at
# the fakes only.
cat >"$TEST_TMP/lib.sh" <<EOF
. "$HERE/xios-session-lib.sh"
xs_kill_pattern='XIOSFAKE-[a-z]+'
xs_shared_kill_pattern='XIOSFAKE-shared-never'
xs_xios_app_kill_pattern='XIOSFAKE-app-never'
EOF
export XIOS_SESSION_LIB="$TEST_TMP/lib.sh"
CLI=("$XS_BASH" "$HERE/xios-session")

# ---- a live non-slot KDE desktop -----------------------------------------------
fake "XIOSFAKE-kwin $XS_JB/Applications/KDE/kwin_wayland.app/kwin_wayland --socket kwin-ios-test"; KWIN=$FAKE
fake "XIOSFAKE-plasma $XS_JB/Applications/KDE/plasmashell.app/plasmashell"; PLASMA=$FAKE
fake "XIOSFAKE-iosc $PFX/local/bin/iosc -s wayland-0"; IOSC=$FAKE
sleep 0.5
printf '%s\tkde-desktop\t-\t2026-10-25T00:00:00\n' "$KWIN" "$PLASMA" "$IOSC" >"$XS_TMP/xios-session.pgids"
printf 'kde-desktop\n' >"$XS_TMP/xios-active-session"
: >"$XS_TMP/wayland-0"
printf '{"width":2880,"height":2160}\n' >"$XS_TMP/xios.json"
STATUS="$XS_TMP/xios-session-status.json"
printf '%s\n' '{"preset":"kde-desktop","state":"up","message":"KWin + Plasma Desktop running","at":"2026-10-25T00:00:00","wayland":"wayland-0"}' >"$STATUS"
PGIDS_BEFORE="$(cat "$XS_TMP/xios-session.pgids")"

kde_untouched() {  # kde_untouched <what>
    alive "$KWIN" && alive "$PLASMA" && alive "$IOSC" || fail "$1 killed the live KDE desktop"
    [ "$(cat "$XS_TMP/xios-active-session")" = kde-desktop ] || fail "$1 changed the active marker"
    [ -e "$XS_TMP/wayland-0" ] && [ -e "$XS_TMP/xios.json" ] || fail "$1 removed KDE's rendezvous files"
    [ "$(cat "$XS_TMP/xios-session.pgids")" = "$PGIDS_BEFORE" ] || fail "$1 rewrote the pgid records"
    [ "$(jget "$STATUS" preset)" = kde-desktop ] && [ "$(jget "$STATUS" state)" = up ] \
        || fail "$1 replaced the live session's preset/state: $(cat "$STATUS")"
    if grep -q 'teardown' "$XS_LOG" 2>/dev/null; then fail "$1 ran a teardown"; fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -m json.tool "$STATUS" >/dev/null || fail "$1 left invalid JSON: $(cat "$STATUS")"
    fi
}

# ---- GNOME over live KDE: refused, nothing stopped, clear message ---------------
rc=0; "${CLI[@]}" gnome >/dev/null 2>&1 || rc=$?
sleep 0.3
[ "$rc" = 69 ] || fail "xios-session gnome exited $rc, want 69 (not installed)"
kde_untouched "xios-session gnome"
[ "$(jget "$STATUS" message)" = "GNOME is not installed: install xios-gnome" ] \
    || fail "unclear refusal message: $(cat "$STATUS")"
[ "$(jget "$STATUS" request)" = gnome ] && [ "$(jget "$STATUS" request_state)" = error ] \
    || fail "refusal not recorded as a request error: $(cat "$STATUS")"
grep -q 'gnome cannot start: GNOME is not installed' "$XS_LOG" || fail "refusal not logged"
echo "ok: gnome over a live KDE desktop is refused before teardown"

# ---- a second refusal replaces the first, never duplicates it -------------------
rc=0; "${CLI[@]}" mutter >/dev/null 2>&1 || rc=$?
[ "$rc" = 69 ] || fail "xios-session mutter exited $rc, want 69"
kde_untouched "xios-session mutter"
[ "$(jget "$STATUS" message)" = "Mutter is not installed: mutter is missing" ] \
    || fail "unclear mutter message: $(cat "$STATUS")"
[ "$(grep -o '"request":' "$STATUS" | wc -l | tr -d ' ')" = 1 ] || fail "request fields duplicated: $(cat "$STATUS")"
[ "$(jget "$STATUS" request)" = mutter ] || fail "second refusal did not replace the first"
echo "ok: a second refusal replaces the first"

# ---- a slot with nothing running: plain error status, no registry entry --------
cp "$STATUS" "$TEST_TMP/global-status"
rc=0; "${CLI[@]}" --slot side gnome >/dev/null 2>&1 || rc=$?
[ "$rc" = 69 ] || fail "--slot side gnome exited $rc, want 69"
SLOT_STATUS="$XS_TMP/xios-session-side.json"
[ "$(jget "$SLOT_STATUS" preset)" = gnome ] && [ "$(jget "$SLOT_STATUS" state)" = error ] \
    || fail "slot refusal status: $(cat "$SLOT_STATUS" 2>/dev/null)"
[ "$(jget "$SLOT_STATUS" message)" = "GNOME is not installed: install xios-gnome" ] || fail "slot message"
[ -e "$XS_TMP/xios-displays.d/side.json" ] && fail "a refused slot was advertised in the display registry"
cmp -s "$STATUS" "$TEST_TMP/global-status" || fail "a slot refusal touched the non-slot status"
kde_untouched "xios-session --slot side gnome"
echo "ok: a refused slot writes its own error status and no registry entry"

# ---- presets lists exactly what can start --------------------------------------
got="$("${CLI[@]}" presets | tr '\n' ' ')"
[ "$got" = "iosc kde kde-desktop kde-nano kde-mobile " ] || fail "presets (no GNOME/mutter): '$got'"
exe "$PFX/bin/gnome-shell"
got="$("${CLI[@]}" presets | tr '\n' ' ')"
case "$got" in *gnome*) fail "gnome listed without gnome-session: '$got'" ;; esac
exe "$PFX/bin/gnome-session"
got="$("${CLI[@]}" presets | tr '\n' ' ')"
[ "$got" = "iosc gnome kde kde-desktop kde-nano kde-mobile " ] || fail "presets with GNOME: '$got'"
rm -f "$XS_JB/Applications/KDE/plasmashell.app/plasmashell"
got="$("${CLI[@]}" presets | tr '\n' ' ')"
[ "$got" = "iosc gnome " ] || fail "presets without plasmashell: '$got'"
rm -f "$PFX/libexec/xios-setsid" "$PFX/bin/launch-gnome-session.sh"
exe "$XS_JB/Applications/KDE/plasmashell.app/plasmashell"
got="$("${CLI[@]}" presets | tr '\n' ' ')"
if command -v setsid >/dev/null 2>&1; then want="iosc kde kde-desktop kde-nano kde-mobile "; else want="iosc "; fi
[ "$got" = "$want" ] || fail "presets without xios-setsid/GNOME launcher: '$got' (want '$want')"
"${CLI[@]}" -d presets >/dev/null || fail "presets -d did not answer locally"
kde_untouched "xios-session presets"
echo "ok: presets lists exactly the flavors that can start"

echo PASS
