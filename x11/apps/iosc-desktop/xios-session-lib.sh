#!/usr/bin/env bash
# The session-launcher core (sourced, never run directly).
#
# One place that knows how to (1) tear down whatever desktop session is currently
# on the iPad and (2) bring up a chosen one, keeping the Xios display app alive.
# Both the on-device CLI (`xios-session`) and ioscd's SESSION handler use this
# file, so there is ONE code path whether Max picks a preset from the Xios app or
# a terminal.
#
# Presets (see xios_session_run):
#   iosc         iosc compositor + wallpaper + panel   (the lightweight desktop; works today)
#   mutter       raw Mutter 46 --wayland               (up: flat stage, no shell yet)
#   gnome        full GNOME session + Shell            (verified first-light path)
#   kde          KWin + desktop plasmashell on iosc    (EXPERIMENTAL)
#   kde-mobile   KWin + Plasma Mobile shell package    (EXPERIMENTAL)
#   kde-nano     KWin + Plasma Nano shell package      (EXPERIMENTAL)
#   app <name>   launch a Wayland client against the RUNNING compositor (no teardown)
#   stop         tear everything down, return to SpringBoard
#
# It REUSES the existing bring-up scripts rather than reinventing them: the iosc
# and mutter presets call run-shell.sh / run-mutter.sh. GNOME uses the packaged
# launch-gnome-session.sh from xios-session-stubs so gnome-session owns the
# Shell component.
# The one thing this library guarantees on top of them is a *bulletproof* teardown
# (gotcha a: kill ALL of iosc/mutter/gnome/KDE/panels/clients + rm every
# stale socket, or the next compositor collides on wayland-0 / the ddx sockets).
#
# Env overrides honoured (passed through to the run scripts):
#   IOSC_LOGICAL        logical desktop size for iosc/ioscd (default 1440x1080)
#   IOSC_PANEL_OPACITY  iosc panel translucency 0-100 (iosc-shell >= 0.9.3; only
#                       forwarded when set, so the panel's 85% default otherwise stands)
#   MUTTER              path to the mutter binary (run-mutter.sh default)
#   XIOS_SESSION_BRINGUP_DIR   override dir to find the run-*.sh scripts
#   XIOS_SESSION_SETTLE   seconds to wait after teardown before starting the next
#                       compositor (default 2) — see the jetsam note below
#   XIOS_SESSION_LOCK_WAIT   seconds to wait for another xios-session operation
#                       to finish before failing busy (default 45)
#   XIOS_SESSION_LOCK_STALE  seconds before a stuck lock owner is reaped
#                       (default 180)
#   XIOS_SESSION_REQUEST_WAIT seconds to wait for the request-sequence marker
#                       while marking a session switch request (default 5)
#   XIOS_SESSION_SWEEP_SLOTS  set to 0 to keep display-slot registry entries whose
#                       socket, config and processes are all gone (default 1:
#                       sweep them, see xs_sweep_stale_slot_registry)
#
# JETSAM NOTE (why the settle exists): switching flavors kills the old compositor
# (which holds a large GPU IOSurface + Metal/ANGLE context, ~30MB) and starts a new
# one that allocates its own surface + context. Doing that back-to-back spikes GPU
# memory and can pressure the foreground Xios app mid-transition. Xios now drops
# its stale IOSurface as soon as the old compositor closes the socket, so presets
# keep the app alive: tear down the old compositor, SETTLE for kernel reclamation,
# then start the new compositor and reconnect the existing display process. An
# explicit `stop` still terminates Xios and returns to SpringBoard.
#
# Status "state" vocabulary (xios-session-status.json):
#   stopping | starting | waiting | relaunching | up | error | stopped | compositor-only
#   | down (a previously-up session died or was torn down; written by teardown,
#     the run-kde-plasma.sh monitor, and ioscd so the Xios picker never shows a
#     stale "up" hours after the session went away)

# ---------------------------------------------------------------------------
# paths + small helpers
# ---------------------------------------------------------------------------
XS_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ "${XS_JB+x}" != x ]; then
    case "$XS_SOURCE_DIR/" in
        /var/jb/*) XS_JB=/var/jb ;;
        *)         XS_JB= ;;
    esac
fi
XS_SUBPREFIX="${XS_SUBPREFIX:-/usr}"
if [ -n "$XS_JB" ]; then
    XS_TMP="${XS_TMP:-$XS_JB/tmp}"
    XS_VAR="${XS_VAR:-$XS_JB/var}"
else
    XS_TMP="${XS_TMP:-${XIOS_RUNTIME_TMP:-/var/tmp}}"
    XS_VAR="${XS_VAR:-${XIOS_RUNTIME_VAR:-/var}}"
fi
XS_PREFIX="${XS_PREFIX:-$XS_JB$XS_SUBPREFIX}"
XS_BIN="${XS_BIN:-$XS_PREFIX/local/bin}"
XS_LIBEXEC_DIR="${XS_LIBEXEC_DIR:-$XS_JB/libexec/xios-session}"
XS_LOG="${XS_LOG:-$XS_TMP/xios-session.log}"
XS_STATUS="${XS_STATUS:-$XS_TMP/xios-session-status.json}"
XS_APP_STATUS="${XS_APP_STATUS:-$XS_TMP/xios-app-launch-status.json}"
XS_ACTIVE="${XS_ACTIVE:-$XS_TMP/xios-active-session}"
XS_LOCK_DIR="${XS_LOCK_DIR:-$XS_TMP/xios-session.lock}"
XS_SESSION_PGIDS="${XS_SESSION_PGIDS:-$XS_TMP/xios-session.pgids}"
XS_REQUEST_SEQ="${XS_REQUEST_SEQ:-$XS_TMP/xios-session.request-seq}"
XS_REQUEST_SEQ_LOCK="${XS_REQUEST_SEQ_LOCK:-$XS_TMP/xios-session.request-seq.lock}"
XS_XIOS_BUNDLE="com.max.xios"
XS_UIOPEN="${XS_UIOPEN:-$XS_PREFIX/bin/uiopen}"
XS_DBUS_RUN="${XS_DBUS_RUN:-$XS_PREFIX/bin/dbus-run-session}"
XS_DBUS_DAEMON="${XS_DBUS_DAEMON:-$XS_PREFIX/bin/dbus-daemon}"
XS_BASH="${XS_BASH:-$XS_PREFIX/bin/bash}"
XS_ANGLE_LIBEGL="${XS_ANGLE_LIBEGL:-$XS_JB/lib/angle/libEGL.angle.dylib}"
XS_PROFILE_LIB="${XS_PROFILE_LIB:-$XS_LIBEXEC_DIR/xios-capability-profiles.sh}"
if [ -r "$XS_PROFILE_LIB" ]; then
    # shellcheck source=./xios-capability-profiles.sh
    . "$XS_PROFILE_LIB"
elif [ -r "$XS_SOURCE_DIR/xios-capability-profiles.sh" ]; then
    # shellcheck source=./xios-capability-profiles.sh
    . "$XS_SOURCE_DIR/xios-capability-profiles.sh"
fi

XS_SLOT_RAW="${XIOS_SESSION_SLOT:-}"
XS_SLOT="$(printf '%s' "$XS_SLOT_RAW" | tr -c 'A-Za-z0-9_.-' '-' | sed 's/^-*//; s/-*$//; s/--*/-/g' | cut -c1-48)"
if [ -n "$XS_SLOT_RAW" ] && [ -z "$XS_SLOT" ]; then XS_SLOT="desktop"; fi
# A slot named "0" would alias the global wayland-0 rendezvous name.
if [ "$XS_SLOT" = 0 ]; then XS_SLOT="slot-0"; fi
XS_SLOT_REGISTRY_DIR="${XS_SLOT_REGISTRY_DIR:-$XS_TMP/xios-displays.d}"
if [ -n "$XS_SLOT" ]; then
    export XIOS_SESSION_SLOT="$XS_SLOT"
    if [ "$XS_STATUS" = "$XS_TMP/xios-session-status.json" ]; then
        XS_STATUS="$XS_TMP/xios-session-$XS_SLOT.json"
    fi
    if [ "$XS_APP_STATUS" = "$XS_TMP/xios-app-launch-status.json" ]; then
        XS_APP_STATUS="$XS_TMP/xios-app-launch-$XS_SLOT.json"
    fi
    XS_SLOT_REGISTRY="$XS_SLOT_REGISTRY_DIR/$XS_SLOT.json"
    XS_WAYLAND_NAME="${XS_WAYLAND_NAME:-wayland-$XS_SLOT}"
    XS_CONFIG_JSON="${XS_CONFIG_JSON:-$XS_TMP/xios-$XS_SLOT.json}"
    XS_IOSC_DDX_SOCK="${XS_IOSC_DDX_SOCK:-$XS_TMP/iosc-$XS_SLOT-ddx.sock}"
    XS_IOSC_INPUT_SOCK="${XS_IOSC_INPUT_SOCK:-$XS_TMP/iosc-$XS_SLOT-input.sock}"
    XS_IOSC_CLIPBOARD_SOCK="${XS_IOSC_CLIPBOARD_SOCK:-$XS_TMP/iosc-$XS_SLOT-clipboard.sock}"
    XS_IOSC_WM_SOCK="${XS_IOSC_WM_SOCK:-$XS_TMP/iosc-$XS_SLOT-wm.sock}"
    XS_MUTTER_DDX_SOCK="${XS_MUTTER_DDX_SOCK:-$XS_TMP/mutter-$XS_SLOT-ddx.sock}"
    XS_MUTTER_INPUT_SOCK="${XS_MUTTER_INPUT_SOCK:-$XS_TMP/mutter-$XS_SLOT-input.sock}"
    XS_MUTTER_CLIPBOARD_SOCK="${XS_MUTTER_CLIPBOARD_SOCK:-$XS_TMP/mutter-$XS_SLOT-clipboard.sock}"
    XS_KWIN_SOCKET="${XS_KWIN_SOCKET:-kwin-$XS_SLOT}"
    XS_IOSC_LOG="${XS_IOSC_LOG:-$XS_TMP/iosc-$XS_SLOT.log}"
    XS_KDE_LOG="${XS_KDE_LOG:-$XS_TMP/kde-plasma-$XS_SLOT.log}"
    # Per-slot helper endpoints, advertised in the slot's registry json so the
    # display app can find the sysintd/a11yd that belong to THIS desktop.
    XS_SYSINT_SOCK="${XS_SYSINT_SOCK:-$XS_TMP/xios-$XS_SLOT-sysint.sock}"
    XS_A11Y_SOCK="${XS_A11Y_SOCK:-$XS_TMP/xios-$XS_SLOT-a11y.sock}"
    XS_APP_BUSDIR="${XS_APP_BUSDIR:-$XS_TMP/xios-session-bus-$XS_SLOT}"
    if [ "$XS_ACTIVE" = "$XS_TMP/xios-active-session" ]; then
        XS_ACTIVE="$XS_TMP/xios-active-session-$XS_SLOT"
    fi
else
    XS_SLOT_REGISTRY=""
    XS_WAYLAND_NAME="${XS_WAYLAND_NAME:-wayland-0}"
    XS_CONFIG_JSON="${XS_CONFIG_JSON:-$XS_TMP/xios.json}"
    XS_IOSC_DDX_SOCK="${XS_IOSC_DDX_SOCK:-$XS_TMP/iosc-ddx.sock}"
    XS_IOSC_INPUT_SOCK="${XS_IOSC_INPUT_SOCK:-$XS_TMP/iosc-input.sock}"
    XS_IOSC_CLIPBOARD_SOCK="${XS_IOSC_CLIPBOARD_SOCK:-$XS_TMP/iosc-clipboard.sock}"
    XS_IOSC_WM_SOCK="${XS_IOSC_WM_SOCK:-$XS_TMP/iosc-wm.sock}"
    XS_MUTTER_DDX_SOCK="${XS_MUTTER_DDX_SOCK:-$XS_TMP/mutter-ddx.sock}"
    XS_MUTTER_INPUT_SOCK="${XS_MUTTER_INPUT_SOCK:-$XS_TMP/mutter-input.sock}"
    XS_MUTTER_CLIPBOARD_SOCK="${XS_MUTTER_CLIPBOARD_SOCK:-$XS_TMP/mutter-clipboard.sock}"
    XS_KWIN_SOCKET="${XS_KWIN_SOCKET:-kwin-ios-test}"
    XS_IOSC_LOG="${XS_IOSC_LOG:-$XS_TMP/iosc.log}"
    XS_KDE_LOG="${XS_KDE_LOG:-$XS_TMP/kde-plasma.log}"
    XS_SYSINT_SOCK="${XS_SYSINT_SOCK:-$XS_TMP/xios-sysint.sock}"
    XS_A11Y_SOCK="${XS_A11Y_SOCK:-$XS_TMP/xios-a11y.sock}"
    XS_APP_BUSDIR="${XS_APP_BUSDIR:-$XS_TMP/xios-session-bus}"
fi
XS_WAYLAND_SOCK="$XS_TMP/$XS_WAYLAND_NAME"

export PATH="$XS_PREFIX/local/bin:$XS_PREFIX/bin:$XS_PREFIX/sbin${XS_JB:+:$XS_JB/bin:$XS_JB/sbin}:/usr/bin:/bin:$PATH"

xs_log() {
    # timestamped line to both the log file and stderr
    local line
    line="$(date '+%Y-%m-%dT%H:%M:%S') $*"
    printf '%s\n' "$line" >>"$XS_LOG" 2>/dev/null || true
    printf 'xios-session: %s\n' "$*" >&2
}

xs_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

xs_json_get_file() {  # xs_json_get_file <file> <key>
    local file="$1" key="$2"
    [ -f "$file" ] || return 0
    sed -n \
        "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p; s/.*\"$key\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" \
        "$file" 2>/dev/null | head -n 1
}

xs_apply_requested_logical() {
    [ -z "${IOSC_LOGICAL:-}" ] || return 0
    local w="${XIOS_SESSION_WIDTH:-}" h="${XIOS_SESSION_HEIGHT:-}"
    case "$w" in ""|*[!0-9]*) return 0 ;; esac
    case "$h" in ""|*[!0-9]*) return 0 ;; esac
    export IOSC_LOGICAL="${w}x${h}"
}

xs_current_pgid() {
    ps -p "$$" -o pgid= 2>/dev/null | tr -d '[:space:]'
}

xs_process_alive() {
    local pid="$1"
    case "$pid" in ""|*[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null
}

xs_lock_dir_with_timeout() {  # xs_lock_dir_with_timeout <dir> <wait-seconds>
    local dir="$1" wait="${2:-5}" waited=0
    while ! mkdir "$dir" 2>/dev/null; do
        if [ "$wait" -le 0 ] || [ "$waited" -ge "$wait" ]; then
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 0
}

xs_switch_request_preset() {
    case "${1:-}" in
        iosc|mutter|gnome|kde|plasma|kde-desktop|plasma-desktop|kde-nano|plasma-nano|nano|kde-mobile|plasma-mobile|mobile|resize|display|stop|off)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

xs_mark_latest_switch_request() {  # xs_mark_latest_switch_request <preset>
    local preset="${1:-session}" seq=0 now
    if ! xs_lock_dir_with_timeout "$XS_REQUEST_SEQ_LOCK" "${XIOS_SESSION_REQUEST_WAIT:-5}"; then
        xs_log "WARN: could not lock session request marker; proceeding without supersede guard"
        XS_REQUEST_ID=""
        return 0
    fi
    if [ -f "$XS_REQUEST_SEQ" ]; then
        seq="$(sed -n '1s/[[:space:]].*//p' "$XS_REQUEST_SEQ" 2>/dev/null || echo 0)"
    fi
    case "$seq" in ""|*[!0-9]*) seq=0 ;; esac
    seq=$((seq + 1))
    now="$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || true)"
    printf '%s\t%s\t%s\t%s\n' "$seq" "$$" "$preset" "$now" >"$XS_REQUEST_SEQ" 2>/dev/null || true
    rmdir "$XS_REQUEST_SEQ_LOCK" 2>/dev/null || true
    XS_REQUEST_ID="$seq"
    export XS_REQUEST_ID
}

xs_switch_request_superseded() {
    local current
    [ -n "${XS_REQUEST_ID:-}" ] || return 1
    [ -f "$XS_REQUEST_SEQ" ] || return 1
    current="$(sed -n '1s/[[:space:]].*//p' "$XS_REQUEST_SEQ" 2>/dev/null || true)"
    [ -n "$current" ] && [ "$current" != "$XS_REQUEST_ID" ]
}

xs_pgid_has_live_session_process() {  # xs_pgid_has_live_session_process <pgid>
    local want="$1"
    case "$want" in ""|*[!0-9]*|0|1) return 1 ;; esac
    ps axww -o pgid=,command= 2>/dev/null | awk -v want="$want" '
        $1 == want {
            $1 = ""
            if ($0 ~ /\/bin\/iosc( |$)|\/bin\/iosc-|ioscbar|ioscdock|ioscoverview|ioscbg|run-kde-plasma\.sh|\/usr\/bin\/mutter|\/usr\/bin\/gnome-shell|gnome-session|kwin_wayland|plasmashell|plasmawindowed|kactivitymanagerd|org_kde_powerdevil|\/Applications\/KDE\/[^ ]+\.app\/[^ ]+|\/bin\/kgx|gnome-text-editor|gnome-calculator|xios-a11yd|xios-audiod|xios-mediad|xios-sysintd|dbus-daemon.*--session|dbus-run-session/) {
                found = 1
            }
        }
        END { exit(found ? 0 : 1) }
    '
}

xs_reap_pgid() {
    local pgid="$1" label="${2:-recorded session}"
    local current
    current="$(xs_current_pgid)"
    case "$pgid" in ""|*[!0-9]*|0|1) return 0 ;; esac
    [ -n "$current" ] && [ "$pgid" = "$current" ] && return 0
    # PGIDs are recycled. A stale registry entry must never be enough to signal
    # an arbitrary process group; require a live, recognizable Xios session
    # process in that group before sending TERM/KILL.
    kill -0 "-$pgid" 2>/dev/null || return 0
    xs_pgid_has_live_session_process "$pgid" || return 0
    xs_log "reaper: killing $label process group $pgid"
    kill -TERM "-$pgid" 2>/dev/null || true
    sleep 0.3
    kill -KILL "-$pgid" 2>/dev/null || true
}

xs_reap_session_lock_owner() {
    local pid pgid preset
    pid="$(cat "$XS_LOCK_DIR/pid" 2>/dev/null || true)"
    pgid="$(cat "$XS_LOCK_DIR/pgid" 2>/dev/null || true)"
    preset="$(cat "$XS_LOCK_DIR/preset" 2>/dev/null || true)"
    xs_log "reaper: clearing stale session lock${pid:+ pid=$pid}${preset:+ preset=$preset}"
    xs_reap_pgid "$pgid" "stale xios-session"
    if xs_process_alive "$pid"; then
        kill -TERM "$pid" 2>/dev/null || true
        sleep 0.3
        xs_process_alive "$pid" && kill -KILL "$pid" 2>/dev/null || true
    fi
    rm -rf "$XS_LOCK_DIR" 2>/dev/null || true
}

xs_session_lock_is_stale() {
    local pid started now age stale
    pid="$(cat "$XS_LOCK_DIR/pid" 2>/dev/null || true)"
    xs_process_alive "$pid" || return 0
    started="$(cat "$XS_LOCK_DIR/started" 2>/dev/null || true)"
    now="$(date '+%s' 2>/dev/null || echo 0)"
    stale="${XIOS_SESSION_LOCK_STALE:-180}"
    case "$started" in ""|*[!0-9]*) return 1 ;; esac
    case "$now" in ""|*[!0-9]*|0) return 1 ;; esac
    case "$stale" in ""|*[!0-9]*|0) return 1 ;; esac
    age=$((now - started))
    [ "$age" -ge "$stale" ]
}

xs_acquire_session_lock() {  # xs_acquire_session_lock <preset>
    local preset="${1:-session}" wait="${XIOS_SESSION_LOCK_WAIT:-45}" waited=0 pgid
    while ! mkdir "$XS_LOCK_DIR" 2>/dev/null; do
        if xs_switch_request_superseded; then
            xs_log "session request '$preset' superseded while waiting; skipping stale request"
            return 75
        fi
        if xs_session_lock_is_stale; then
            xs_reap_session_lock_owner
            continue
        fi
        if [ "$wait" -le 0 ] || [ "$waited" -ge "$wait" ]; then
            xs_log "session busy: another xios-session operation is still running"
            xs_write_status "$preset" error "another session operation is still running"
            return 75
        fi
        [ "$waited" -eq 0 ] && {
            xs_log "session busy: waiting for current xios-session operation"
            xs_write_status "$preset" waiting "waiting for current session operation"
        }
        sleep 1
        waited=$((waited + 1))
    done

    pgid="$(xs_current_pgid)"
    printf '%s\n' "$$" >"$XS_LOCK_DIR/pid" 2>/dev/null || true
    printf '%s\n' "$pgid" >"$XS_LOCK_DIR/pgid" 2>/dev/null || true
    printf '%s\n' "$preset" >"$XS_LOCK_DIR/preset" 2>/dev/null || true
    date '+%s' >"$XS_LOCK_DIR/started" 2>/dev/null || true
    if xs_switch_request_superseded; then
        xs_log "session request '$preset' superseded before start; skipping stale request"
        xs_release_session_lock
        return 75
    fi
    return 0
}

xs_release_session_lock() {
    local owner
    owner="$(cat "$XS_LOCK_DIR/pid" 2>/dev/null || true)"
    [ "$owner" = "$$" ] && rm -rf "$XS_LOCK_DIR" 2>/dev/null || true
}

xs_a11y_enabled() {
    [ -e "$XS_TMP/xios-a11y-enabled" ] && return 0
    [ -e "$XS_TMP/xios-a11y-force" ] && return 0
    case "${XIOS_ENABLE_A11Y:-}" in
        1|yes|YES|true|TRUE|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

xs_a11y_start_cmd() {
    local source_dir helper
    source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    for helper in \
        "${XIOS_A11Y_START:-}" \
        "$XS_BIN/xios-start-a11y" \
        "$XS_LIBEXEC_DIR/xios-start-a11y" \
        "$source_dir/xios-start-a11y"; do
        [ -n "$helper" ] && [ -x "$helper" ] && { printf '%s' "$helper"; return 0; }
    done
    command -v xios-start-a11y 2>/dev/null || true
}

xs_a11y_prefix() {
    local helper
    xs_a11y_enabled || return 0
    helper="$(xs_a11y_start_cmd)"
    [ -n "$helper" ] && printf '%s; ' "$helper"
}

xs_session_bus_address() {  # xs_session_bus_address <busdir>
    local busdir="$1" sock addr out pid
    sock="$busdir/session-bus"
    addr="unix:path=$sock"
    mkdir -p "$busdir"; chmod 0700 "$busdir"
    if [ -S "$sock" ]; then
        printf '%s' "$addr"
        return 0
    fi
    [ -x "$XS_DBUS_DAEMON" ] || return 1
    rm -f "$sock"
    # --fork detaches the daemon into its own session, so no recorded process
    # group will ever contain it. Keep its pid beside the socket: that is what
    # lets `--slot X stop` (and only that) take the bus down again.
    out="$("$XS_DBUS_DAEMON" --session --fork --address="$addr" --print-address --print-pid 2>/dev/null)" || return 1
    pid="$(printf '%s\n' "$out" | sed -n '2p' | tr -cd '0-9')"
    [ -n "$pid" ] && printf '%s\n' "$pid" >"$busdir/bus.pid" 2>/dev/null
    if [ -S "$sock" ]; then
        printf '%s' "$addr"
        return 0
    fi
    return 1
}

# Stop the standalone session bus in <busdir> iff its recorded pid is still a
# dbus-daemon serving exactly that directory (pids get recycled).
xs_stop_bus_dir() {  # xs_stop_bus_dir <busdir>
    local busdir="$1" pid cmd
    [ -n "$busdir" ] && [ -d "$busdir" ] || return 0
    pid="$(cat "$busdir/bus.pid" 2>/dev/null || true)"
    if xs_process_alive "$pid"; then
        cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
        case "$cmd" in
            *dbus-daemon*"$busdir/session-bus"*) kill -TERM "$pid" 2>/dev/null || true ;;
        esac
    fi
}

# Live and still the program we started? (pid files outlive reboots, pids recycle)
xs_pidfile_running() {  # xs_pidfile_running <pidfile> <program-name>
    local pf="$1" name="$2" pid cmd
    pid="$(cat "$pf" 2>/dev/null || true)"
    xs_process_alive "$pid" || return 1
    cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
    case "$cmd" in *"$name"*) return 0 ;; esac
    return 1
}

xs_start_native_helper() {  # xs_start_native_helper <binary> <log> <busdir> <bus_addr>
    local bin="$1" log="$2" busdir="$3" bus_addr="$4" name pf
    [ -x "$bin" ] || return 0
    name="${bin##*/}"
    # One instance per session bus. This used to be "skip if ANY instance runs"
    # (a global ps grep), which left every desktop after the first without its
    # helper -- and, for sysintd, without a socket of its own.
    pf="$busdir/$name.pid"
    xs_pidfile_running "$pf" "$name" && return 0
    nohup env \
        XDG_RUNTIME_DIR="$busdir" \
        DBUS_SESSION_BUS_ADDRESS="$bus_addr" \
        DBUS_SYSTEM_BUS_ADDRESS="$bus_addr" \
        XIOS_HWBRIDGE_BUS=session \
        XIOS_SYSINT_SOCK="$XS_SYSINT_SOCK" \
        XIOS_A11Y_SOCK="$XS_A11Y_SOCK" \
        PULSE_SERVER="${PULSE_SERVER:-unix:$XS_TMP/pulse/native}" \
        PULSE_RUNTIME_PATH="${PULSE_RUNTIME_PATH:-$XS_TMP/pulse-daemon}" \
        GSETTINGS_BACKEND=memory \
        HOME="$XS_VAR/root" \
        PATH="$XS_BIN:$XS_PREFIX/bin:$XS_PREFIX/sbin${XS_JB:+:$XS_JB/bin:$XS_JB/sbin}:/usr/bin:/bin:$PATH" \
        "$bin" >"$log" 2>&1 </dev/null &
    printf '%s\n' "$!" >"$pf" 2>/dev/null || true
}

xs_start_native_helpers() {  # xs_start_native_helpers <busdir> <bus_addr>
    local busdir="$1" bus_addr="$2" profile
    [ -n "$bus_addr" ] || return 0
    profile="$XS_JB/etc/profile.d/xios-pulse.sh"
    [ -r "$profile" ] && . "$profile" && xios_pulse_start
    xs_start_native_helper "$XS_PREFIX/libexec/xios-hwbridged" "$XS_TMP/xios-hwbridged${XS_SLOT:+-$XS_SLOT}.log" "$busdir" "$bus_addr"
    xs_start_native_helper "$XS_PREFIX/libexec/xios-sensord" "$XS_TMP/xios-sensord${XS_SLOT:+-$XS_SLOT}.log" "$busdir" "$bus_addr"
    xs_start_native_helper "$XS_PREFIX/libexec/xios-sysintd" "$XS_TMP/xios-sysintd${XS_SLOT:+-$XS_SLOT}.log" "$busdir" "$bus_addr"
}

# PulseAudio's module-xios-sink and xios-hwbridged hardcode the GLOBAL sysintd
# path to push desktop volume/brightness back to the iPad. PulseAudio stays
# shared across desktops, so while no non-slot session owns that path, point it at
# a live slot's sysintd instead. A real sysintd binding the default path later
# simply replaces the link (the server unlinks before bind).
xs_publish_default_sysint_link() {
    local def="$XS_TMP/xios-sysint.sock"
    [ -n "$XS_SLOT" ] || return 0
    [ -S "$XS_SYSINT_SOCK" ] || return 0
    if [ -L "$def" ] || [ ! -e "$def" ]; then
        ln -sfn "$XS_SYSINT_SOCK" "$def" 2>/dev/null || true
    fi
}

xs_retract_default_sysint_link() {  # xs_retract_default_sysint_link <slot-socket>
    local def="$XS_TMP/xios-sysint.sock" tgt
    [ -L "$def" ] || return 0
    tgt="$(readlink "$def" 2>/dev/null || true)"
    [ "$tgt" = "$1" ] && rm -f "$def" 2>/dev/null || true
    xs_relink_default_sysint "$1"
}

# Point the default path at any OTHER live slot's sysintd (skipping <except>).
xs_relink_default_sysint() {  # xs_relink_default_sysint [except-socket]
    local def="$XS_TMP/xios-sysint.sock" e sock
    [ -L "$def" ] || [ ! -e "$def" ] || return 0
    [ ! -e "$def" ] || return 0
    for e in "$XS_SLOT_REGISTRY_DIR"/*.json; do
        [ -f "$e" ] || continue
        sock="$(xs_json_get_file "$e" sysint_socket)"
        [ -n "$sock" ] && [ "$sock" != "${1:-}" ] && [ -S "$sock" ] || continue
        ln -sfn "$sock" "$def" 2>/dev/null && return 0
    done
    return 0
}

# xs_write_status <preset> <state> <message>
#   state = starting | up | error | stopped   (the app / CLI can poll this)
xs_write_status() {
    local preset="$1" state="$2" msg="$3"
    local at active width height stride display ddx socket input_socket meta="" extra=""
    at="$(date '+%Y-%m-%dT%H:%M:%S')"
    case "$state" in up|compositor-only) xs_publish_default_sysint_link ;; esac
    active="$(cat "$XS_ACTIVE" 2>/dev/null || true)"
    width="$(xs_json_get_file "$XS_CONFIG_JSON" width)"
    height="$(xs_json_get_file "$XS_CONFIG_JSON" height)"
    stride="$(xs_json_get_file "$XS_CONFIG_JSON" stride)"
    display="$(xs_json_get_file "$XS_CONFIG_JSON" display)"
    ddx="$(xs_json_get_file "$XS_CONFIG_JSON" ddx)"
    socket="$(xs_json_get_file "$XS_CONFIG_JSON" socket)"
    input_socket="$(xs_json_get_file "$XS_CONFIG_JSON" input_socket)"
    [ -n "$active" ] && extra="$extra,\"active\":\"$(xs_json_escape "$active")\""
    [ -n "$XS_SLOT" ] && meta="$meta,\"slot\":\"$(xs_json_escape "$XS_SLOT")\""
    [ -n "$XS_WAYLAND_NAME" ] && meta="$meta,\"wayland\":\"$(xs_json_escape "$XS_WAYLAND_NAME")\""
    [ -n "$XS_CONFIG_JSON" ] && meta="$meta,\"json\":\"$(xs_json_escape "$XS_CONFIG_JSON")\""
    # Per-session helper endpoints (the paths this desktop's sysintd/a11yd listen
    # on; the display app checks the socket exists before connecting).
    [ -n "$XS_SYSINT_SOCK" ] && meta="$meta,\"sysint_socket\":\"$(xs_json_escape "$XS_SYSINT_SOCK")\""
    [ -n "$XS_A11Y_SOCK" ] && meta="$meta,\"a11y_socket\":\"$(xs_json_escape "$XS_A11Y_SOCK")\""
    [ -n "$width" ] && extra="$extra,\"width\":$width"
    [ -n "$height" ] && extra="$extra,\"height\":$height"
    [ -n "$stride" ] && extra="$extra,\"stride\":$stride"
    [ -n "$display" ] && extra="$extra,\"display\":\"$(xs_json_escape "$display")\""
    [ -n "$ddx" ] && extra="$extra,\"ddx\":\"$(xs_json_escape "$ddx")\""
    [ -n "$socket" ] && extra="$extra,\"socket\":\"$(xs_json_escape "$socket")\""
    [ -n "$input_socket" ] && extra="$extra,\"input_socket\":\"$(xs_json_escape "$input_socket")\""
    [ -n "${IOSC_LOGICAL:-}" ] && extra="$extra,\"requested_logical\":\"$(xs_json_escape "$IOSC_LOGICAL")\""
    [ -n "${XIOS_SESSION_DPI:-}" ] && extra="$extra,\"requested_dpi\":$XIOS_SESSION_DPI"
    printf '{"preset":"%s","state":"%s","message":"%s","at":"%s"%s}\n' \
        "$(xs_json_escape "$preset")" "$(xs_json_escape "$state")" \
        "$(xs_json_escape "$msg")" "$at" "$meta$extra" >"$XS_STATUS" 2>/dev/null || true
    if [ -n "$XS_SLOT_REGISTRY" ]; then
        mkdir -p "$XS_SLOT_REGISTRY_DIR" 2>/dev/null || true
        printf '{"slot":"%s","preset":"%s","state":"%s","message":"%s","at":"%s","wayland":"%s","json":"%s","status":"%s","sysint_socket":"%s","a11y_socket":"%s"%s}\n' \
            "$(xs_json_escape "$XS_SLOT")" "$(xs_json_escape "$preset")" \
            "$(xs_json_escape "$state")" "$(xs_json_escape "$msg")" "$at" \
            "$(xs_json_escape "$XS_WAYLAND_NAME")" "$(xs_json_escape "$XS_CONFIG_JSON")" \
            "$(xs_json_escape "$XS_STATUS")" \
            "$(xs_json_escape "$XS_SYSINT_SOCK")" "$(xs_json_escape "$XS_A11Y_SOCK")" \
            "$extra" >"$XS_SLOT_REGISTRY" 2>/dev/null || true
    fi
}

# Additive client launches must never replace the display owner's status. The
# Xios picker and ioscd use XS_STATUS as the single desktop lifecycle record;
# writing app:* there made an eventual compositor exit unable to mark itself
# down. Keep app submission diagnostics in their own file.
xs_write_app_status() {  # xs_write_app_status <app> <state> <message> [pid]
    local app="$1" state="$2" msg="$3" pid="${4:-}" owner at extra=""
    owner="$(cat "$XS_ACTIVE" 2>/dev/null || true)"
    at="$(date '+%Y-%m-%dT%H:%M:%S')"
    [ -n "$owner" ] && extra="$extra,\"owner\":\"$(xs_json_escape "$owner")\""
    [ -n "$XS_SLOT" ] && extra="$extra,\"slot\":\"$(xs_json_escape "$XS_SLOT")\""
    case "$pid" in
        ""|*[!0-9]*) ;;
        *) extra="$extra,\"pid\":$pid" ;;
    esac
    printf '{"app":"%s","state":"%s","message":"%s","at":"%s"%s}\n' \
        "$(xs_json_escape "$app")" "$(xs_json_escape "$state")" \
        "$(xs_json_escape "$msg")" "$at" "$extra" >"$XS_APP_STATUS" 2>/dev/null || true
}

# The active-display owner. /var/jb/tmp/xios.json is a single pointer to the
# framebuffer Xios should show; it is not a compositor registry. Keep a tiny owner
# marker beside it so helpers such as ioscd know whether they are allowed to start
# classic iosc and overwrite that pointer.
xs_set_active() {
    local preset="$1"
    printf '%s\n' "$preset" >"$XS_ACTIVE" 2>/dev/null || true
}

xs_clear_active() {
    rm -f "$XS_ACTIVE" 2>/dev/null || true
}

xs_record_session_pgid() {
    local preset="${1:-session}" pgid slot="${XS_SLOT:--}"
    pgid="$(xs_current_pgid)"
    case "$pgid" in ""|*[!0-9]*|0|1) return 0 ;; esac
    printf '%s\t%s\t%s\t%s\n' "$pgid" "$preset" "$slot" "$(date '+%Y-%m-%dT%H:%M:%S')" >>"$XS_SESSION_PGIDS" 2>/dev/null || true
}

xs_record_pgid_once() {
    local pgid="$1" preset="${2:-session}" slot="${3:-${XS_SLOT:-}}" at
    case "$pgid" in ""|*[!0-9]*|0|1) return 0 ;; esac
    [ -n "$slot" ] || slot="-"
    if [ -f "$XS_SESSION_PGIDS" ] && awk -v pgid="$pgid" -v slot="$slot" 'BEGIN{found=1} $1==pgid && $3==slot {found=0} END{exit found}' "$XS_SESSION_PGIDS" 2>/dev/null; then
        return 0
    fi
    at="$(date '+%Y-%m-%dT%H:%M:%S')"
    printf '%s\t%s\t%s\t%s\n' "$pgid" "$preset" "$slot" "$at" >>"$XS_SESSION_PGIDS" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# process ownership (several desktops run at once; nothing may kill a neighbour)
# ---------------------------------------------------------------------------
# A desktop's processes are identified, in order of trust, by:
#   1. a recorded process group (xs_record_pgid_once), validated against a live
#      session process before it is ever signalled (xs_reap_pgid);
#   2. an argv needle that names the slot exactly (xs_slot_regex).
# Anything else is not provably ours and is left alone.

# One process-table snapshot: "pid ppid pgid command...". Callers filter it with
# awk, never with `grep -q` (an early-exiting grep SIGPIPEs ps under pipefail and
# reads as "no match", which is how a live slot used to get swept).
xs_ps_table() {
    ps axww -o pid=,ppid=,pgid=,command= 2>/dev/null || true
}

# ERE matching every argv a slot's processes carry (and no other slot's: each
# alternative ends at a character that cannot continue a slot name).
xs_slot_regex() {  # xs_slot_regex <slot>
    local s B='([^A-Za-z0-9_.-]|$)'
    s="$(printf '%s' "$1" | sed 's/\./\\./g')"
    printf '%s' "(wayland|kwin|xios-run|xios-kde-runtime|xios-session-bus|gnome-session-bus|kde-session-bus)-${s}${B}|(iosc|mutter)-${s}-(ddx|input|clipboard|wm)\\.sock|xios-${s}(\\.json|-sysint\\.sock|-a11y\\.sock)${B}"
}

# Pids whose argv names <slot> (never this shell or its parent).
xs_slot_pids() {  # xs_slot_pids <slot>
    local re
    re="$(xs_slot_regex "$1")"
    xs_ps_table | SLOT_RE="$re" awk -v me="$$" -v pp="$PPID" '
        { pid = $1; if (pid == me || pid == pp) next
          c = $0; sub(/^ *[0-9]+ +[0-9]+ +[0-9]+ +/, "", c)
          if (c ~ /^(awk|ps|grep|sed) /) next
          if (c ~ ENVIRON["SLOT_RE"]) print pid }'
}

# Real slot names from the pgid records and the display registry (the pgid file
# also holds legacy rows whose slot column is "-" or a timestamp).
xs_known_slots() {
    local e
    {
        [ -f "$XS_SESSION_PGIDS" ] && awk -F'\t' '$3 != "" && $3 != "-" && $3 !~ /^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ { print $3 }' "$XS_SESSION_PGIDS"
        for e in "$XS_SLOT_REGISTRY_DIR"/*.json; do
            [ -f "$e" ] && basename "$e" .json
        done
        [ -n "${XS_SLOT:-}" ] && printf '%s\n' "$XS_SLOT"
    } 2>/dev/null | sort -u
}

xs_slot_recorded_pgids() {  # xs_slot_recorded_pgids <slot>
    [ -f "$XS_SESSION_PGIDS" ] || return 0
    awk -F'\t' -v want="$1" '$3 == want && $1 ~ /^[0-9]+$/ { print $1 }' "$XS_SESSION_PGIDS" | sort -u
}

# Every pid that belongs to ANY slot: recorded pgids, argv needles, every other
# member of those process groups, and all of their descendants. A non-slot
# teardown subtracts this from whatever its pattern matches.
xs_slot_protected_pids() {
    local slots slot re="" pgids=""
    slots="$(xs_known_slots)"
    [ -n "$slots" ] || return 0
    for slot in $slots; do
        re="${re:+$re|}$(xs_slot_regex "$slot")"
        pgids="$pgids $(xs_slot_recorded_pgids "$slot" | tr '\n' ' ')"
    done
    xs_ps_table | SLOT_RE="$re" PGIDS="$pgids" awk '
        BEGIN { n = split(ENVIRON["PGIDS"], a, " "); for (i = 1; i <= n; i++) pgset[a[i]] = 1 }
        { pid = $1; ppid[pid] = $2; pg[pid] = $3
          c = $0; sub(/^ *[0-9]+ +[0-9]+ +[0-9]+ +/, "", c)
          if (c ~ /^(awk|ps|grep|sed) /) next
          if (($3 in pgset) || c ~ ENVIRON["SLOT_RE"]) { seed[pid] = 1 } }
        END {
            for (p in seed) if (pg[p] > 1) pgset[pg[p]] = 1
            for (p in pg) if (pg[p] in pgset) prot[p] = 1
            for (round = 0; round < 12; round++) {
                grew = 0
                for (p in pg) if (!(p in prot) && (ppid[p] in prot) && ppid[p] > 1) { prot[p] = 1; grew = 1 }
                if (!grew) break
            }
            for (p in prot) print p
        }'
}

xs_record_pgid_of_pid() {  # xs_record_pgid_of_pid <pid> [preset] [slot]
    local pid="$1" preset="${2:-session}" slot="${3:-${XS_SLOT:-}}" pgid
    case "$pid" in ""|*[!0-9]*|0|1) return 0 ;; esac
    pgid="$(ps -p "$pid" -o pgid= 2>/dev/null | tr -d '[:space:]')"
    xs_record_pgid_once "$pgid" "$preset" "$slot"
}

# Record the process groups of everything this session just started. Slot mode
# finds them by the slot's argv needles; the global session by the fixed global
# names. Either way the NEXT teardown reaps by pgid instead of by pattern.
xs_record_slot_process_pgroups() {
    local preset="${1:-session}" pid pids
    if [ -n "${XS_SLOT:-}" ]; then
        pids="$(xs_slot_pids "$XS_SLOT")"
    else
        pids="$(
            xs_ps_table | awk -v me="$$" -v pp="$PPID" '
                { c = $0; sub(/^ *[0-9]+ +[0-9]+ +[0-9]+ +/, "", c)
                  if ($1 == me || $1 == pp || c ~ /^(awk|ps|grep|sed) /) next
                  if (c ~ /iosc-(ddx|input|clipboard|wm)\.sock|(-s|--wayland-display) wayland-0( |$)|--socket kwin-ios-test( |$)/) print $1 }'
        )"
    fi
    for pid in $pids; do
        xs_record_pgid_of_pid "$pid" "$preset"
    done
}

# GNOME re-parents itself through xios-setsid, so its group is new and unrelated
# to ours; launch-gnome-session.sh leaves the group id in a file for us.
xs_record_gnome_pgid() {
    local f="$XS_TMP/xios-gnome${XS_SLOT:+-$XS_SLOT}.pgid" pgid
    pgid="$(tr -cd '0-9' <"$f" 2>/dev/null || true)"
    case "$pgid" in ""|0|1) return 0 ;; esac
    xs_record_pgid_once "$pgid" gnome "${XS_SLOT:-}"
}

xs_reap_recorded_session_pgroups() {
    [ -f "$XS_SESSION_PGIDS" ] || return 0
    local tmp="$XS_SESSION_PGIDS.$$" pgid preset slot at current
    current="$(xs_current_pgid)"
    : >"$tmp" 2>/dev/null || true
    while IFS=$'\t' read -r pgid preset slot at; do
        case "$pgid" in ""|*[!0-9]*|0|1) continue ;; esac
        # New records use "-" for the global (non-slot) field. Older records
        # wrote an empty tab field; Bash collapses adjacent whitespace delimiters,
        # so their timestamp was read into `slot` and every global compositor was
        # accidentally protected as slot-owned.
        case "$slot" in
            -) slot="" ;;
            20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*) at="$slot"; slot="" ;;
        esac
        if [ -n "$slot" ]; then
            printf '%s\t%s\t%s\t%s\n' "$pgid" "$preset" "$slot" "$at" >>"$tmp" 2>/dev/null || true
            continue
        fi
        [ -n "$current" ] && [ "$pgid" = "$current" ] && continue
        # A group recorded for BOTH the global session and a slot (two sessions
        # started from one script share a pgid) stays: the slot wins.
        if xs_pgid_has_slot "$pgid"; then
            printf '%s\t%s\t%s\t%s\n' "$pgid" "$preset" "-" "$at" >>"$tmp" 2>/dev/null || true
            continue
        fi
        xs_reap_pgid "$pgid" "previous ${preset:-session}"
    done <"$XS_SESSION_PGIDS"
    if [ -s "$tmp" ]; then
        mv "$tmp" "$XS_SESSION_PGIDS" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    else
        rm -f "$XS_SESSION_PGIDS" "$tmp" 2>/dev/null || true
    fi
}

xs_reap_slot_session_pgroups() {
    local want="$1"
    [ -n "$want" ] || return 0
    [ -f "$XS_SESSION_PGIDS" ] || return 0
    local tmp="$XS_SESSION_PGIDS.$$" pgid preset slot at current
    current="$(xs_current_pgid)"
    : >"$tmp" 2>/dev/null || true
    while IFS=$'\t' read -r pgid preset slot at; do
        case "$pgid" in ""|*[!0-9]*|0|1) continue ;; esac
        case "$slot" in
            -) slot="" ;;
            20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*) at="$slot"; slot="" ;;
        esac
        if [ "$slot" = "$want" ]; then
            [ -n "$current" ] && [ "$pgid" = "$current" ] && continue
            # A group recorded for another slot or the non-slot session too is
            # shared (two sessions started from one script); signalling it would
            # kill the neighbour. The needle pass reaps this slot's own processes.
            if xs_pgid_has_other_owner "$pgid" "$want"; then
                xs_log "slot $want: process group $pgid is shared with another session; reaping by name instead"
                continue
            fi
            xs_reap_pgid "$pgid" "slot $want ${preset:-session}"
        else
            printf '%s\t%s\t%s\t%s\n' "$pgid" "$preset" "$slot" "$at" >>"$tmp" 2>/dev/null || true
        fi
    done <"$XS_SESSION_PGIDS"
    mv "$tmp" "$XS_SESSION_PGIDS" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

xs_reap_slot_named_processes() {
    local slot="$1" pid
    [ -n "$slot" ] || return 0
    for pid in $(xs_slot_pids "$slot"); do
        case "$pid" in ""|*[!0-9]*|0|1|$$|$PPID) continue ;; esac
        kill -TERM "$pid" 2>/dev/null || true
    done
    sleep 0.5
    for pid in $(xs_slot_pids "$slot"); do
        case "$pid" in ""|*[!0-9]*|0|1|$$|$PPID) continue ;; esac
        kill -KILL "$pid" 2>/dev/null || true
    done
}

# Shell clients (ioscbg/ioscbar/ioscdock) carry no slot in their argv; run-shell.sh
# records each one's pid in <name>-wayland-<slot>.pid. Kill those that are still the
# program they were (pids recycle).
xs_reap_slot_pidfiles() {  # xs_reap_slot_pidfiles <slot>
    local slot="${1:?slot}" pf pid name wayland entry="$XS_SLOT_REGISTRY_DIR/$1.json"
    wayland="$(xs_json_get_file "$entry" wayland)"
    [ -n "$wayland" ] || wayland="wayland-$slot"
    for pf in "${XS_TMP:?}"/*-"$wayland".pid; do
        [ -f "$pf" ] || continue
        name="$(basename "$pf" ".pid")"; name="${name%-$wayland}"
        pid="$(cat "$pf" 2>/dev/null || true)"
        xs_pidfile_running "$pf" "$name" || continue
        kill -TERM "$pid" 2>/dev/null || true
    done
}

# Is any compositor/shell process still serving this slot? This is the ONLY
# liveness test that means anything: every file a slot leaves in $XS_TMP
# outlives the process that made it (nothing unlinks a slot's socket on crash,
# jetsam or reboot, and $XS_TMP is not cleared at boot).
#
# Two independent proofs, either is enough:
#   - a recorded process group of the slot still holds a live session process
#     (this is what keeps a GNOME slot alive: gnome-shell's argv names no slot);
#   - a process whose argv names the slot exactly.
# Keeping a dead slot is merely untidy; sweeping a live one deletes a running
# desktop's sockets.
xs_slot_has_live_process() {
    local slot="$1" pgid
    for pgid in $(xs_slot_recorded_pgids "$slot"); do
        xs_pgid_has_live_session_process "$pgid" && return 0
    done
    [ -n "$(xs_slot_pids "$slot")" ] && return 0
    return 1
}

# A slot's runtime state is only deleted on clean stop; crashes/jetsam/reboots
# leave the whole per-slot footprint behind, and the Xios app keeps listing the
# entry. Sweep every slot with no live process.
#
# This used to skip a slot whose socket or config file still existed, which
# inverted the test: a leftover socket is the SYMPTOM of a dead session, not
# evidence of a live one, so the two file guards short-circuited before the
# process check and the only slots that ever got swept were the ones that had
# already cleaned up after themselves. Slots that died dirty -- the ones this
# function exists for -- accumulated in $XS_TMP indefinitely, across reboots.
xs_sweep_stale_slot_registry() {
    case "${XIOS_SESSION_SWEEP_SLOTS:-1}" in 0|no|off|false) return 0 ;; esac
    [ -d "$XS_SLOT_REGISTRY_DIR" ] || return 0
    local entry slot swept=0
    for entry in "$XS_SLOT_REGISTRY_DIR"/*.json; do
        [ -f "$entry" ] || continue
        slot="$(basename "$entry" .json)"
        [ -n "${XS_SLOT:-}" ] && [ "$slot" = "$XS_SLOT" ] && continue
        xs_slot_has_live_process "$slot" && continue
        # Logs are left alone on purpose: they are the only post-mortem left
        # for whatever killed the session.
        xs_remove_slot_state "$slot" "$entry"
        swept=$((swept + 1))
        xs_log "swept stale display slot '$slot' (no live process)"
    done
    [ "$swept" -gt 0 ] && xs_log "sweep removed $swept stale display slot(s)"
    xs_prune_dead_pgid_rows
    return 0
}

# Drop pgid records of slots that have no registry entry and nothing alive. The
# sweep above only walks the registry, so a slot whose entry was already removed
# (clean stop, an older launcher) would otherwise keep its rows -- and keep its
# name in every future protected-pid computation -- forever.
xs_prune_dead_pgid_rows() {
    [ -f "$XS_SESSION_PGIDS" ] || return 0
    local slot dead=""
    for slot in $(awk -F'\t' '$3 != "" && $3 != "-" && $3 !~ /^20[0-9][0-9]-/ { print $3 }' "$XS_SESSION_PGIDS" | sort -u); do
        [ -n "${XS_SLOT:-}" ] && [ "$slot" = "$XS_SLOT" ] && continue
        [ -f "$XS_SLOT_REGISTRY_DIR/$slot.json" ] && continue
        xs_slot_has_live_process "$slot" && continue
        dead="$dead $slot"
    done
    [ -n "$dead" ] || return 0
    DEAD="$dead" awk -F'\t' 'BEGIN { n = split(ENVIRON["DEAD"], a, " "); for (i = 1; i <= n; i++) d[a[i]] = 1 }
        !($3 in d)' "$XS_SESSION_PGIDS" >"$XS_SESSION_PGIDS.$$" 2>/dev/null &&
        mv "$XS_SESSION_PGIDS.$$" "$XS_SESSION_PGIDS" 2>/dev/null || rm -f "$XS_SESSION_PGIDS.$$" 2>/dev/null
    xs_log "pruned pgid records of dead slots:$dead"
    return 0
}

# Delete one slot's rendezvous files, sockets, bus and markers. Safe to call for
# a slot that is already dead; callers establish that (or have just killed it).
xs_remove_slot_state() {  # xs_remove_slot_state <slot> [registry-entry]
    local slot="${1:?slot}" entry="${2:-$XS_SLOT_REGISTRY_DIR/$1.json}" wayland config sysint t="${XS_TMP:?}"
    wayland="$(xs_json_get_file "$entry" wayland)"
    [ -n "$wayland" ] || wayland="wayland-$slot"
    config="$(xs_json_get_file "$entry" json)"
    [ -n "$config" ] || config="$t/xios-$slot.json"
    sysint="$(xs_json_get_file "$entry" sysint_socket)"
    [ -n "$sysint" ] || sysint="$t/xios-$slot-sysint.sock"

    rm -f "$t/$wayland" "$t/$wayland.lock" "$config" \
          "$t/iosc-$slot-ddx.sock" "$t/iosc-$slot-input.sock" \
          "$t/iosc-$slot-clipboard.sock" "$t/iosc-$slot-wm.sock" \
          "$t/mutter-$slot-ddx.sock" "$t/mutter-$slot-input.sock" \
          "$t/mutter-$slot-clipboard.sock" \
          "$t/kwin-$slot" "$t/kwin-$slot.lock" \
          "$sysint" "$t/xios-$slot-a11y.sock" \
          "$t/gnome-session-bus-$slot" "$t/xios-gnome-$slot.pgid" \
          "$t/xios-active-session-$slot" \
          "$t/xios-session-$slot.json" "$t/xios-app-launch-$slot.json" \
          "$t/xios-status.d/iosc-$slot.status" "$t/xios-status.d/iosc-native-$slot.status" \
          "$t"/*-"$wayland".pid 2>/dev/null || true
    xs_retract_default_sysint_link "$sysint"
    xs_stop_bus_dir "$t/xios-session-bus-$slot"
    rm -rf "$t/xios-session-bus-$slot" "$t/xios-kde-runtime-$slot" \
           "$t/xios-run-$slot" 2>/dev/null || true
    rm -f "$entry" 2>/dev/null || true
}

# Is <pgid> also recorded for an owner other than <slot> (another slot, or the
# non-slot session)?
xs_pgid_has_other_owner() {  # xs_pgid_has_other_owner <pgid> <slot>
    local want="$1" me="$2" pgid preset slot at
    [ -f "$XS_SESSION_PGIDS" ] || return 1
    while IFS=$'\t' read -r pgid preset slot at; do
        [ "$pgid" = "$want" ] || continue
        case "$slot" in
            20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*) slot="-" ;;
            "") slot="-" ;;
        esac
        [ "$slot" != "$me" ] && return 0
    done <"$XS_SESSION_PGIDS"
    return 1
}

xs_pgid_has_slot() {
    local want="$1" pgid preset slot at
    case "$want" in ""|*[!0-9]*|0|1) return 1 ;; esac
    [ -f "$XS_SESSION_PGIDS" ] || return 1
    while IFS=$'\t' read -r pgid preset slot at; do
        case "$slot" in
            -|20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*) slot="" ;;
        esac
        [ "$pgid" = "$want" ] && [ -n "$slot" ] && return 0
    done <"$XS_SESSION_PGIDS"
    return 1
}

xs_pid_belongs_to_slot() {
    local pid="$1" pgid
    case "$pid" in ""|*[!0-9]*|0|1) return 1 ;; esac
    pgid="$(ps -p "$pid" -o pgid= 2>/dev/null | tr -d '[:space:]')"
    xs_pgid_has_slot "$pgid"
}

xs_first_readable() {
    local c
    for c in "$@"; do
        [ -n "$c" ] && [ -r "$c" ] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

# Resolve one of the bring-up scripts. In global mode prefer the live installed
# owner script so package edits track automatically. In slot mode prefer the
# pinned libexec script first because stale live owner scripts can silently drop
# slot-specific env/argv.
xs_find_bringup() {
    local name="$1" override="${XIOS_SESSION_BRINGUP_DIR:+$XIOS_SESSION_BRINGUP_DIR/$name}"
    if [ -n "$XS_SLOT" ]; then
        xs_first_readable \
            "$override" \
            "$XS_LIBEXEC_DIR/$name" \
            "$XS_BIN/$name" \
            "$XS_JB/usr/bin/$name"
    else
        xs_first_readable \
            "$override" \
            "$XS_BIN/$name" \
            "$XS_JB/usr/bin/$name" \
            "$XS_LIBEXEC_DIR/$name"
    fi
}

# ---------------------------------------------------------------------------
# teardown (gotcha a) — kill every compositor/client + rm every stale socket
# ---------------------------------------------------------------------------
# Union of the teardown greps in the compositor/app bring-up scripts, anchored
# to binary paths so it never matches this script itself
# (xios-session) or our own shell. We additionally exclude $$ and
# the parent pid as belt-and-braces.
#
# This is only the FALLBACK for global-session processes nobody recorded (a
# session started by an older launcher). Recorded process groups are reaped
# first, and anything provably owned by a slot is subtracted before a single
# signal is sent, so a non-slot start or stop never touches a running slot.
xs_kill_pattern='/bin/iosc( |$)|/bin/iosc-|ioscbar|ioscdock|ioscoverview|ioscbg|run-kde-plasma\.sh|/usr/bin/mutter|/usr/bin/gnome-shell|gnome-session|kwin_wayland|plasmashell|plasmawindowed|kactivitymanagerd|org_kde_powerdevil|/Applications/KDE/[^ ]+\.app\/[^ ]+|/bin/kgx|gnome-text-editor|gnome-calculator|xios-a11yd|xios-sysintd|dbus-daemon.*--session|dbus-run-session'
# Shared desktop services (one per device, used by every desktop). Only an
# everything-is-stopping teardown may touch these; switching or stopping one
# desktop must leave another desktop's audio alone.
xs_shared_kill_pattern='xios-audiod|xios-mediad|pactl (info|set-sink-volume xios)|paplay .*xios|mpv --player-operation-mode=pseudo-gui'
xs_xios_app_kill_pattern='/Xios\.app/Xios'

# Pids matching <pattern>, minus this shell, its parent and every slot-owned
# process. The pattern travels in the environment so awk does not rewrite its
# backslashes.
xs_teardown_candidates() {  # xs_teardown_candidates <ere>
    local prot
    prot=" $(xs_slot_protected_pids | tr '\n' ' ') "
    ps axww -o pid=,command= 2>/dev/null | KILL_RE="$1" PROT="$prot" awk -v self="$$" -v parent="$PPID" '
        { pid = $1; if (pid == self || pid == parent) next
          if (index(ENVIRON["PROT"], " " pid " ")) next
          c = $0; sub(/^ *[0-9]+ +/, "", c)
          if (c ~ /^(awk|ps|grep|sed) /) next
          if (c ~ ENVIRON["KILL_RE"]) print pid }'
}

# xios_session_teardown <why> [kill-display-app 0|1] [kill-shared 0|1]
xios_session_teardown() {
    local why="${1:-switching sessions}"
    local kill_display_app="${2:-0}" kill_shared="${3:-0}" kill_pattern="$xs_kill_pattern"
    if [ "$kill_shared" = 1 ]; then
        kill_pattern="$kill_pattern|$xs_shared_kill_pattern"
    fi
    if [ "$kill_display_app" = 1 ]; then
        kill_pattern="$kill_pattern|$xs_xios_app_kill_pattern"
    fi
    xs_log "teardown ($why): killing the non-slot session$([ "$kill_shared" = 1 ] && printf ' + shared services')$([ "$kill_display_app" = 1 ] && printf ' + Xios app')"
    xs_reap_recorded_session_pgroups
    local pid pids
    pids="$(xs_teardown_candidates "$kill_pattern")"
    for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
    sleep 1
    pids="$(xs_teardown_candidates "$kill_pattern")"
    for pid in $pids; do
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    done
    # Remove every stale rendezvous/socket file for the GLOBAL compositor paths
    # (slot sessions use suffixed names and are never listed here).
    local t="${XS_TMP:?}"
    rm -f "$XS_WAYLAND_SOCK" "$XS_WAYLAND_SOCK.lock" \
          "$XS_CONFIG_JSON" \
          "$XS_A11Y_SOCK" "$XS_SYSINT_SOCK" \
          "$XS_IOSC_DDX_SOCK" "$XS_IOSC_INPUT_SOCK" \
          "$XS_IOSC_CLIPBOARD_SOCK" "$XS_IOSC_WM_SOCK" \
          "$XS_MUTTER_DDX_SOCK" "$XS_MUTTER_INPUT_SOCK" \
          "$XS_MUTTER_CLIPBOARD_SOCK" \
          "$t/kwin-ios-test" "$t/kwin-ios-test.lock" \
          "$t/kde-session-bus" \
          "$t/iosc-wm.sock" \
          "$t/iosc-native.sock" \
          "$t/xios-gnome.pgid" \
          "$t"/*-wayland-0.pid 2>/dev/null || true
    rm -rf "$t/xios-kde-runtime" 2>/dev/null || true
    rm -f "$t/xios-status.d/iosc.status" 2>/dev/null || true
    xs_relink_default_sysint
    xs_stop_bus_dir "$t/xios-session-bus"
    rm -rf "$t/xios-session-bus" 2>/dev/null || true
    # Never leave a dead session advertised as running: if the status file still
    # claims a live state after everything was killed, rewrite it as down. Catches
    # teardowns arriving outside the normal preset flow (which already writes
    # "stopping" first).
    local st_state st_preset
    st_state="$(xs_json_get_file "$XS_STATUS" state)"
    case "$st_state" in
        up|compositor-only|waiting|starting|relaunching)
            st_preset="$(xs_json_get_file "$XS_STATUS" preset)"
            xs_write_status "${st_preset:-session}" down "session torn down ($why)"
            ;;
    esac
    xs_log "teardown done"
}

# Let the mobile-owned Xios app connect to root-created rendezvous sockets.
xs_fix_ddx_perms() {
    local s
    for s in "$XS_TMP"/*-ddx.sock; do
        [ -S "$s" ] || continue
        if chown mobile:mobile "$s" 2>/dev/null || chown 501:501 "$s" 2>/dev/null; then
            chmod 0660 "$s" 2>/dev/null || true
        else
            chmod 0600 "$s" 2>/dev/null || true
            xs_log "WARN: could not hand $s to mobile; keeping it owner-only"
        fi
    done
}

# Foreground the Xios display app. NOTE (gotcha b): if the iPad screen is asleep
# or locked, FrontBoard suspends the Metal app and it presents nil — the caller
# must have the screen awake + unlocked. We can't force that from a daemon.
xs_foreground_xios() {
    if [ -n "${XS_SLOT:-}" ] && [ "${XIOS_SLOT_FOREGROUND:-0}" != 1 ]; then
        xs_log "slot $XS_SLOT: leaving Xios foreground unchanged"
        return 0
    fi
    (
        "$XS_UIOPEN" -b "$XS_XIOS_BUNDLE" 2>/dev/null \
            || "$XS_UIOPEN" "$XS_XIOS_BUNDLE" 2>/dev/null || true
    ) &
    local pid=$! i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt "${XIOS_UIOPEN_WAIT_TICKS:-20}" ]; do
        sleep 0.25
        i=$((i + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        xs_log "WARN: uiopen did not return promptly; leaving foreground request best-effort"
        kill -TERM "$pid" 2>/dev/null || true
        sleep 0.2
        kill -KILL "$pid" 2>/dev/null || true
    else
        wait "$pid" 2>/dev/null || true
    fi
}

xs_wait_socket() {  # xs_wait_socket <path> <tries>
    local p="$1" n="${2:-40}" i=0
    while [ ! -S "$p" ] && [ "$i" -lt "$n" ]; do sleep 0.2; i=$((i+1)); done
    [ -S "$p" ]
}

# Let the kernel reclaim the old compositor's GPU IOSurface + context before the
# next compositor allocates, so the two don't co-reside and pressure the app.
# Xios remains alive but releases the old IOSurface on compositor EOF. Tunable.
xs_settle() {
    local s="${XIOS_SESSION_SETTLE:-2}"
    xs_log "settling ${s}s (freeing the old GPU surface before the next compositor allocates)"
    sleep "$s"
}

# Make sure the Xios display app is up after the new compositor exists. Normally
# it survived the switch and only needs foregrounding; if iOS terminated it,
# relaunch it and mark the status "relaunching display".
xs_ensure_xios() {  # xs_ensure_xios <preset>
    local preset="${1:-session}"
    # procps/pgrep is not a base dependency on the iPad. Use the same portable
    # process-table probe as the rest of this launcher so a live Xios process is
    # not falsely reported as missing on every switch.
    if ps axww 2>/dev/null | grep -v grep | grep -E '/Xios\.app/Xios( |$)' >/dev/null 2>&1; then
        xs_foreground_xios
        return 0
    fi
    xs_log "Xios app not running; relaunching display"
    xs_write_status "$preset" relaunching "relaunching display (Xios app)"
    xs_foreground_xios
    sleep 1
}

# ---------------------------------------------------------------------------
# presets
# ---------------------------------------------------------------------------

xs_prepare_display_session() {  # xs_prepare_display_session <preset>
    local preset="$1"
    xs_write_status "$preset" stopping "stopping current session"
    if [ -n "$XS_SLOT" ]; then
        if [ -S "$XS_WAYLAND_SOCK" ] || [ -f "$XS_CONFIG_JSON" ]; then
            xs_log "ERROR: slot '$XS_SLOT' already has a display; stop it before replacing it"
            xs_write_status "$preset" error "slot already running: $XS_SLOT"
            return 1
        fi
        xs_set_active "$preset"
    else
        xios_session_teardown "-> $preset"
        xs_settle
        xs_set_active "$preset"
    fi
    xs_record_session_pgid "$preset"
}

# iosc: teardown, then run-shell.sh (starts iosc + wallpaper + panel), then fix
# the ddx socket perms + foreground Xios (run-shell.sh does neither — it just
# says "open the Xios app"). This is the flavor that works today.
xios_session_iosc() {
    xs_prepare_display_session iosc || return $?
    xs_write_status iosc starting "starting iosc + shell"
    local script; script="$(xs_find_bringup run-shell.sh)" || {
        xs_log "ERROR: run-shell.sh not found (install iosc-shell)"; xs_write_status iosc error "run-shell.sh missing"; return 1; }
    xs_log "iosc: $script"
    # Only export IOSC_PANEL_OPACITY when the caller set it, so an unset value
    # never overrides the panel's own 85% default.
    export IOSC_LOGICAL="${IOSC_LOGICAL:-1440x1080}"
    export WAYLAND_DISPLAY="$XS_WAYLAND_NAME"
    export XIOS_JSON_PATH="$XS_CONFIG_JSON"
    export IOSC_DDX_SOCK="$XS_IOSC_DDX_SOCK"
    export IOSC_INPUT_SOCK="$XS_IOSC_INPUT_SOCK"
    export IOSC_CLIPBOARD_SOCK="$XS_IOSC_CLIPBOARD_SOCK"
    export IOSC_WM_SOCK="$XS_IOSC_WM_SOCK"
    export IOSC_LOG="$XS_IOSC_LOG"
    export XIOS_SYSINT_SOCK="$XS_SYSINT_SOCK" XIOS_A11Y_SOCK="$XS_A11Y_SOCK"
    [ -n "$XS_SLOT" ] && export IOSC_IGNORE_ACTIVE_SESSION=1
    [ -n "${IOSC_PANEL_OPACITY:-}" ] && export IOSC_PANEL_OPACITY
    sh "$script" || true
    xs_record_slot_process_pgroups iosc
    xs_write_status iosc waiting "waiting for compositor surface"
    if ! xs_wait_socket "$XS_WAYLAND_SOCK" 50; then
        xs_log "ERROR: iosc did not create wayland-0"; xs_write_status iosc error "wayland-0 never appeared"; return 1
    fi
    xs_fix_ddx_perms
    xs_ensure_xios iosc
    xs_log "iosc up. Awake the Xios app to see the desktop."
    xs_write_status iosc up "iosc + shell running"
}

# mutter: teardown, then run-mutter.sh. That script does its own (now redundant)
# teardown, starts mutter --wayland, chowns the ddx socket and relaunches Xios.
xios_session_mutter() {
    xs_prepare_display_session mutter || return $?
    xs_write_status mutter starting "starting mutter --wayland (compositor + display)"
    local script; script="$(xs_find_bringup run-mutter.sh)" || {
        xs_log "ERROR: run-mutter.sh not found"; xs_write_status mutter error "run-mutter.sh missing"; return 1; }
    xs_log "mutter: $script"
    # run-mutter.sh's own (now no-op) teardown finds nothing to kill after ours +
    # the settle, so it just starts mutter, waits for xios.json, and relaunches Xios.
    WAYLAND_DISPLAY="$XS_WAYLAND_NAME" \
    XIOS_JSON_PATH="$XS_CONFIG_JSON" \
    XIOS_DDX_SOCKET="$XS_MUTTER_DDX_SOCK" \
    XIOS_INPUT_SOCKET="$XS_MUTTER_INPUT_SOCK" \
    XIOS_CLIPBOARD_SOCKET="$XS_MUTTER_CLIPBOARD_SOCK" \
    XIOS_SYSINT_SOCK="$XS_SYSINT_SOCK" \
    XIOS_A11Y_SOCK="$XS_A11Y_SOCK" \
    XIOS_SESSION_SLOT="$XS_SLOT" \
    MUTTER_LOG="${XS_TMP}/mutter${XS_SLOT:+-$XS_SLOT}.log" \
    bash "$script" || true
    # mutter's argv names the slot (--wayland-display wayland-<slot>), so its
    # process group is found by needle; record it for the slot-scoped stop.
    xs_record_slot_process_pgroups mutter
    xs_ensure_xios mutter   # relaunch the display if it got jetsammed during bring-up
    if [ -f "$XS_CONFIG_JSON" ]; then
        xs_log "mutter up (flat clutter stage; no shell yet)."
        xs_write_status mutter up "mutter --wayland running"
    else
        xs_log "ERROR: mutter did not write xios.json (see $XS_TMP/mutter.log)"
        xs_write_status mutter error "mutter failed; see mutter.log"; return 1
    fi
}

# gnome: teardown, then launch-gnome-session.sh from xios-session-stubs. The
# launcher verifies the package-time gnome-shell GPU entitlement set, starts the
# freedesktop/iOS bridge services on one private session bus, then runs
# gnome-session --builtin --session=xios so gnome-session owns org.gnome.Shell.
xios_session_gnome() {
    xs_prepare_display_session gnome || return $?
    xs_write_status gnome starting "starting GNOME session"
    local script; script="$(xs_find_bringup launch-gnome-session.sh)" || {
        xs_log "ERROR: launch-gnome-session.sh not found (install xios-session-stubs)"
        xs_write_status gnome error "launch-gnome-session.sh missing"
        return 1
    }
    xs_log "gnome session: $script"
    WAYLAND_DISPLAY="$XS_WAYLAND_NAME" \
    XIOS_JSON_PATH="$XS_CONFIG_JSON" \
    XIOS_DDX_SOCKET="$XS_MUTTER_DDX_SOCK" \
    XIOS_INPUT_SOCKET="$XS_MUTTER_INPUT_SOCK" \
    XIOS_CLIPBOARD_SOCKET="$XS_MUTTER_CLIPBOARD_SOCK" \
    XIOS_SYSINT_SOCK="$XS_SYSINT_SOCK" \
    XIOS_A11Y_SOCK="$XS_A11Y_SOCK" \
    XIOS_GNOME_PGID_FILE="$XS_TMP/xios-gnome${XS_SLOT:+-$XS_SLOT}.pgid" \
    GNOME_SHELL_LOG="${XS_TMP}/gnome-shell${XS_SLOT:+-$XS_SLOT}.log" \
    XIOS_SESSION_SLOT="$XS_SLOT" \
    bash "$script" || true
    # launch-gnome-session.sh re-parents the whole session through xios-setsid;
    # its new process group is reported in a pgid file. Record it before anything
    # else can run, so neither the stale-slot sweep nor a non-slot teardown can
    # mistake a live GNOME for an orphan.
    xs_record_gnome_pgid
    xs_record_slot_process_pgroups gnome
    xs_ensure_xios gnome    # relaunch the display if it got jetsammed during bring-up
    xs_write_status gnome waiting "waiting for GNOME Shell to paint"
    # Do NOT gate "gnome up" on xios.json: Mutter writes it before the gjs shell
    # loads, so it only proves the compositor came up. The real marker is "GNOME
    # Shell started at" in gnome-shell.log, printed after the JS UI loads. Poll
    # for that, a hard failure, or process exit (~15s); report each distinctly.
    local log="$XS_TMP/gnome-shell${XS_SLOT:+-$XS_SLOT}.log" i=0 outcome=timeout
    # Optional out-of-process Shell services share this log and may emit their
    # own JS errors without affecting the compositor or UI. Only treat errors
    # that identify the main Shell entry point or GPU backend as fatal here;
    # process exit remains the authoritative general failure signal.
    local fail_re='Execution of main\.js threw exception|MTLCreateSystemDefaultDevice'
    while [ "$i" -lt 30 ]; do
        if grep -q "GNOME Shell started at" "$log" 2>/dev/null; then outcome=started; break; fi
        if grep -qE "$fail_re" "$log" 2>/dev/null; then outcome=failed; break; fi
        xios_session_process_running "/usr/bin/gnome-shell|gnome-session.*--session=xios" || { outcome=exited; break; }
        sleep 0.5; i=$((i+1))
    done
    case "$outcome" in
        started)
            xs_log "GNOME session painted (GNOME Shell started)."
            xs_write_status gnome up "GNOME Shell started" ;;
        failed|exited)
            xs_log "gnome-shell FAILED ($outcome). Last 40 lines of $log:"
            tail -40 "$log" 2>/dev/null | while IFS= read -r ln; do xs_log "  | $ln"; done
            xs_write_status gnome error "gnome-shell $outcome; see gnome-shell.log"
            return 1 ;;
        timeout)
            if [ -f "$XS_CONFIG_JSON" ]; then
                xs_log "gnome-shell: Mutter up but no 'GNOME Shell started' after ~15s (compositor-only). Last 40 lines of $log:"
                tail -40 "$log" 2>/dev/null | while IFS= read -r ln; do xs_log "  | $ln"; done
                xs_write_status gnome compositor-only "Mutter up; GNOME Shell JS did not report started (see gnome-shell.log)"
            else
                xs_log "gnome-shell: no xios.json and no start marker; bring-up failed."
                xs_write_status gnome error "gnome-shell did not start; see gnome-shell.log"
                return 1
            fi ;;
    esac
}

# kde: EXPERIMENTAL. Starts iosc as the output compositor, then runs nested
# kwin_wayland and plasmashell on KWin's own Wayland socket. The flavor selects
# the Plasma shell package via PLASMA_DEFAULT_SHELL where needed. This mirrors the
# proven KWin nested smoke instead of treating KWin as a native Xios display
# server.
xios_session_process_running() {
    ps axww | grep -v grep | grep -E "$1" >/dev/null 2>&1
}

xs_kde_runtime_dir() {
    if [ -n "${XS_SLOT:-}" ]; then
        printf '%s/xios-kde-runtime-%s\n' "$XS_TMP" "$XS_SLOT"
    else
        printf '%s/xios-kde-runtime\n' "$XS_TMP"
    fi
}

xs_prepare_kde_runtime_dir() {
    local dir
    dir="$(xs_kde_runtime_dir)"
    rm -rf "$dir" 2>/dev/null || true
    mkdir -p "$dir" || return 1
    chmod 0700 "$dir" 2>/dev/null || true
    printf '%s\n' "$dir"
}

xios_session_kde_kwin_running() {
    if [ -n "${XS_SLOT:-}" ]; then
        ps axww | grep -v grep | grep -F "kwin_wayland" | grep -F -- "--socket $XS_KWIN_SOCKET" >/dev/null 2>&1
    else
        xios_session_process_running "kwin_wayland"
    fi
}

xios_session_kde_shell_running() {
    if [ -n "${XS_SLOT:-}" ]; then
        [ -S "$(xs_kde_runtime_dir)/$XS_KWIN_SOCKET" ] && ! grep -qE "plasmashell exited|kwin exited|KWin did not create|kwin socket did not appear" "$XS_KDE_LOG" 2>/dev/null
    else
        xios_session_process_running "plasmashell"
    fi
}

xios_session_kde() {
    local flavor="${1:-xios}" preset="kde" label="KWin + plasmashell" plasma_shell_plugin=""
    case "$flavor" in
        xios|plasma|kde) flavor=desktop; preset=kde; label="KWin + Plasma Desktop"; plasma_shell_plugin="org.kde.plasma.desktop" ;;
        desktop|plasma-desktop|kde-desktop) flavor=desktop; preset=kde-desktop; label="KWin + Plasma Desktop"; plasma_shell_plugin="org.kde.plasma.desktop" ;;
        nano|plasma-nano|kde-nano) flavor=nano; preset=kde-nano; label="KWin + Plasma Nano" ;;
        mobile|phone|plasma-mobile|kde-mobile) flavor=mobile; preset=kde-mobile; label="KWin + Plasma Mobile" ;;
        *) xs_log "ERROR: unknown KDE flavor '$flavor'"; xs_write_status kde error "unknown KDE flavor: $flavor"; return 2 ;;
    esac
    xs_prepare_display_session "$preset" || return $?
    xs_write_status "$preset" starting "starting $label (experimental)"
    local script; script="$(xs_find_bringup run-kde-plasma.sh)" || {
        xs_log "ERROR: run-kde-plasma.sh not found"; xs_write_status "$preset" error "run-kde-plasma.sh missing"; return 1; }
    local kde_runtime
    kde_runtime="$(xs_prepare_kde_runtime_dir)" || {
        xs_log "ERROR: could not create KDE runtime dir"; xs_write_status "$preset" error "KDE runtime dir failed"; return 1; }
    xs_log "$preset (experimental): $script"
    xs_log "$preset runtime: $kde_runtime"
    XDG_RUNTIME_DIR="$kde_runtime" \
    WAYLAND_DISPLAY="$XS_WAYLAND_NAME" \
    XIOS_JSON_PATH="$XS_CONFIG_JSON" \
    IOSC_DDX_SOCK="$XS_IOSC_DDX_SOCK" \
    IOSC_INPUT_SOCK="$XS_IOSC_INPUT_SOCK" \
    IOSC_CLIPBOARD_SOCK="$XS_IOSC_CLIPBOARD_SOCK" \
    IOSC_WM_SOCK="$XS_IOSC_WM_SOCK" \
    IOSC_LOG="$XS_IOSC_LOG" \
    KWIN_SOCKET="$XS_KWIN_SOCKET" \
    KDE_LOG="$XS_KDE_LOG" \
    XIOS_SESSION_SLOT="$XS_SLOT" \
    XIOS_SYSINT_SOCK="$XS_SYSINT_SOCK" \
    XIOS_A11Y_SOCK="$XS_A11Y_SOCK" \
    XIOS_SESSION_STATUS_FILE="$XS_STATUS" \
    XIOS_SESSION_STATUS_PRESET="$preset" \
    XIOS_SESSION_ACTIVE_FILE="$XS_ACTIVE" \
    PLASMA_SHELL_PLUGIN="${plasma_shell_plugin:-${PLASMA_SHELL_PLUGIN-}}" \
    KDE_PLASMA_FLAVOR="$flavor" bash "$script" || true
    xs_record_slot_process_pgroups "$preset"
    xs_ensure_xios "$preset"
    xs_write_status "$preset" waiting "waiting for $label"
    local i=0 kde_failed=0 kde_ready=0
    while [ "$i" -lt 20 ]; do
        if grep -qE "plasmashell exited|kwin exited|KWin did not create|kwin socket did not appear" "$XS_KDE_LOG" 2>/dev/null; then
            kde_failed=1
            break
        fi
        if xios_session_kde_kwin_running && xios_session_kde_shell_running; then
            kde_ready=1
            break
        fi
        sleep 0.5
        i=$((i+1))
    done
    if [ "$kde_ready" = 1 ]; then
        sleep 0.5
        if ! xios_session_kde_kwin_running || ! xios_session_kde_shell_running; then
            kde_ready=0
        fi
    fi
    if [ "$kde_ready" = 0 ] && [ "$kde_failed" = 0 ]; then
        if grep -qE "plasmashell exited|kwin exited|KWin did not create|kwin socket did not appear" "$XS_KDE_LOG" 2>/dev/null; then
            kde_failed=1
        fi
    fi
    if [ "$kde_failed" = 1 ]; then
        xs_log "$preset FAILED: shell/compositor exited; see $XS_KDE_LOG"
        tail -40 "$XS_KDE_LOG" 2>/dev/null | while IFS= read -r ln; do xs_log "  | $ln"; done
        xs_write_status "$preset" error "$label exited; see kde-plasma.log"
        return 1
    elif [ "$kde_ready" = 1 ]; then
        xs_log "$preset up ($XS_KWIN_SOCKET + plasmashell running)."
        xs_write_status "$preset" up "$label running"
    elif xios_session_kde_kwin_running || [ -S "$kde_runtime/$XS_KWIN_SOCKET" ]; then
        xs_log "$preset compositor up, but plasmashell is not running; see $XS_KDE_LOG"
        xs_write_status "$preset" compositor-only "KWin running; plasmashell not confirmed"
    else
        xs_log "ERROR: KWin is not running; see $XS_KDE_LOG"
        xs_write_status "$preset" error "KWin failed; see kde-plasma.log"
        return 1
    fi
}

# app <name>: launch a Wayland client against the CURRENTLY RUNNING compositor.
# No teardown — this rides on whatever compositor is up. Reuses run-kgx.sh's proven
# client environment (shared session bus dir, absolute WAYLAND_DISPLAY, GDK wayland,
# GTK ngl on ANGLE/IOSurface, memory gsettings, writable HOME).
xios_session_app() {
    local name="$1"
    [ -n "$name" ] || {
        xs_log "ERROR: 'app' needs a name"
        xs_write_app_status "" error "no app name"
        return 1
    }
    local owner
    owner="$(cat "$XS_ACTIVE" 2>/dev/null || true)"
    local compositor_sock="$XS_WAYLAND_SOCK"
    case "$owner" in
        gnome)
            compositor_sock="$XS_TMP/xios-run${XS_SLOT:+-$XS_SLOT}/$XS_WAYLAND_NAME" ;;
        kde|kde-desktop|kde-nano|kde-mobile|plasma|plasma-desktop|plasma-nano|plasma-mobile)
            compositor_sock="$(xs_kde_runtime_dir)/$XS_KWIN_SOCKET" ;;
    esac
    if [ ! -S "$compositor_sock" ]; then
        xs_log "ERROR: no compositor running (no $compositor_sock). Pick iosc/mutter/gnome first."
        xs_write_app_status "$name" error "no compositor; start a session first"
        return 1
    fi
    xs_write_app_status "$name" starting "submitting $name"

    # name -> exec. kgx is special: a bare `kgx` registers as the GApplication
    # primary and returns WITHOUT mapping a window in this bus-only environment, so
    # it must be given an explicit command that stays alive (run-kgx.sh gotcha).
    local exec
    case "$name" in
        kgx|console|gnome-console)          exec="kgx -T iosc-kgx -- $XS_BASH -i" ;;
        text-editor|gnome-text-editor|editor) exec="gnome-text-editor" ;;
        calculator|gnome-calculator|calc)   exec="gnome-calculator" ;;
        *)                                  exec="$name" ;;   # run as given
    esac

    local busdir="$XS_APP_BUSDIR" addr
    local app_runtime="$busdir" app_wayland="$XS_WAYLAND_SOCK"
    local app_env=() client_env=() kv profile_pairs
    if [ "$owner" = gnome ]; then
        app_runtime="$XS_TMP/xios-run${XS_SLOT:+-$XS_SLOT}"
        app_wayland="$XS_WAYLAND_NAME"
    fi
    if command -v xios_profile_env_pairs >/dev/null 2>&1; then
        profile_pairs="$(xios_profile_env_pairs iosc-client-gpu)"
        while IFS= read -r kv; do
            [ -n "$kv" ] && client_env+=("$kv")
        done <<<"$profile_pairs"
    else
        client_env=(
            GDK_BACKEND=wayland
            GSK_RENDERER=ngl
            QT_QPA_PLATFORM="${IOSC_QT_QPA_PLATFORM:-wayland-egl}"
            QT_WAYLAND_DISABLE_WINDOWDECORATION="${QT_WAYLAND_DISABLE_WINDOWDECORATION:-1}"
            ANGLE_REAL_LIBEGL="$XS_ANGLE_LIBEGL"
            GSETTINGS_BACKEND=memory
            LANG="${LANG:-C}"
            LC_CTYPE="${LC_CTYPE:-UTF-8}"
            FC_LANG="${FC_LANG:-en}"
            XCOMPOSEFILE="${XCOMPOSEFILE:-$XS_PREFIX/share/X11/locale/en_US.UTF-8/Compose}"
        )
    fi
    xs_log "app: launching '$exec' as a wayland client of the running compositor"
    local a11y_prefix
    a11y_prefix="$(xs_a11y_prefix)"
    local gtk_a11y_env=()
    xs_a11y_enabled || gtk_a11y_env=(GTK_A11Y=none)
    local dbus_addr=()
    case "$owner" in
        gnome)
            local gnome_bus_file="$XS_TMP/gnome-session-bus${XS_SLOT:+-$XS_SLOT}"
            if [ -s "$gnome_bus_file" ]; then
                addr="$(cat "$gnome_bus_file" 2>/dev/null || true)"
                [ -n "$addr" ] && dbus_addr=(
                    DBUS_SESSION_BUS_ADDRESS="$addr"
                    DBUS_SYSTEM_BUS_ADDRESS="$addr"
                )
            fi
            ;;
        kde|kde-desktop|kde-nano|kde-mobile|plasma|plasma-desktop|plasma-nano|plasma-mobile)
            if [ -S "$compositor_sock" ]; then
                app_runtime="$(xs_kde_runtime_dir)"
                app_wayland="$XS_KWIN_SOCKET"
                if command -v xios_profile_env_pairs >/dev/null 2>&1; then
                    profile_pairs="$(xios_profile_env_pairs plasma-egl)"
                    while IFS= read -r kv; do
                        [ -n "$kv" ] && app_env+=("$kv")
                    done <<<"$profile_pairs"
                else
                    app_env+=(
                        DYLD_LIBRARY_PATH="$XS_PREFIX/lib:$XS_JB/lib/angle"
                        XDG_DATA_DIRS="$XS_PREFIX/share"
                        XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$XS_VAR/root/.config}"
                        XDG_CONFIG_DIRS="$XS_JB/etc/xdg:$XS_PREFIX/etc/xdg"
                        GSETTINGS_SCHEMA_DIR="$XS_PREFIX/share/glib-2.0/schemas"
                        KDE_FULL_SESSION=true
                        KDE_SESSION_VERSION=6
                        XDG_CURRENT_DESKTOP=KDE
                        XDG_SESSION_TYPE=wayland
                        QT_PLUGIN_PATH="$XS_PREFIX/lib/qt6/plugins"
                        QML2_IMPORT_PATH="$XS_PREFIX/lib/qt6/qml"
                        QML_IMPORT_PATH="$XS_PREFIX/lib/qt6/qml"
                        QSG_RHI_BACKEND="${QSG_RHI_BACKEND:-opengl}"
                        QT_QPA_PLATFORM="${PLASMA_QT_QPA_PLATFORM:-wayland-egl}"
                        QT_WAYLAND_CLIENT_BUFFER_INTEGRATION="${QT_WAYLAND_CLIENT_BUFFER_INTEGRATION:-wayland-egl}"
                        QT_QUICK_CONTROLS_STYLE="${QT_QUICK_CONTROLS_STYLE:-org.kde.desktop}"
                    )
                fi
                if ls "$XS_PREFIX"/lib/qt6/plugins/platformthemes/KDEPlasmaPlatformTheme6.* >/dev/null 2>&1; then
                    app_env+=(QT_QPA_PLATFORMTHEME="${QT_QPA_PLATFORMTHEME:-kde}")
                fi
                if ls "$XS_PREFIX"/lib/qt6/plugins/styles/breeze6.* >/dev/null 2>&1; then
                    app_env+=(QT_STYLE_OVERRIDE="${QT_STYLE_OVERRIDE:-Breeze}")
                fi
                local kde_bus_file="$app_runtime/kde-session-bus${XS_SLOT:+-$XS_SLOT}"
                if [ -s "$kde_bus_file" ]; then
                    addr="$(cat "$kde_bus_file" 2>/dev/null || true)"
                    [ -n "$addr" ] && dbus_addr=(DBUS_SESSION_BUS_ADDRESS="$addr" DBUS_SYSTEM_BUS_ADDRESS="$addr")
                fi
            fi
            ;;
    esac
    if [ ${#dbus_addr[@]} -eq 0 ] && addr="$(xs_session_bus_address "$busdir")"; then
        dbus_addr=(DBUS_SESSION_BUS_ADDRESS="$addr" DBUS_SYSTEM_BUS_ADDRESS="$addr")
        xs_start_native_helpers "$busdir" "$addr"
    fi
    local launcher=("$XS_BASH" -lc "${a11y_prefix}exec $exec")
    if [ ${#dbus_addr[@]} -eq 0 ]; then
        launcher=("$XS_DBUS_RUN" -- ${launcher[@]+"${launcher[@]}"})
    fi
    # Give the client its own process group (xios-session-stubs ships xios-setsid),
    # so a slot stop can reap it by group without ever sharing a group with another
    # desktop's clients when several sessions are started from one script.
    local setsid_cmd=""
    [ -x "$XS_PREFIX/libexec/xios-setsid" ] && setsid_cmd="$XS_PREFIX/libexec/xios-setsid"
    nohup ${setsid_cmd:+"$setsid_cmd"} env \
        XDG_RUNTIME_DIR="$app_runtime" \
        WAYLAND_DISPLAY="$app_wayland" \
        XIOS_A11Y_SOCK="$XS_A11Y_SOCK" \
        XIOS_A11YD_LOG="$XS_TMP/xios-a11yd${XS_SLOT:+-$XS_SLOT}.log" \
        XIOS_ATSPI_LOG="$XS_TMP/xios-atspi${XS_SLOT:+-$XS_SLOT}.log" \
        ${client_env[@]+"${client_env[@]}"} \
        ${app_env[@]+"${app_env[@]}"} \
        ${gtk_a11y_env[@]+"${gtk_a11y_env[@]}"} \
        ${dbus_addr[@]+"${dbus_addr[@]}"} \
        HOME="$XS_VAR/root" \
        ${launcher[@]+"${launcher[@]}"} \
        >>"$XS_TMP/xios-session-client.log" 2>&1 </dev/null &
    local app_pid=$!
    # Record the client's group so a later stop of THIS session (and only it)
    # takes the client down with the rest of the desktop.
    [ -z "$setsid_cmd" ] || xs_record_pgid_of_pid "$app_pid" "app:$name"
    # bring the shared Xios display forward so the new window is visible
    xs_foreground_xios
    xs_log "app '$name' submitted (pid $app_pid). Window maps into the current compositor."
    xs_write_app_status "$name" submitted "$name launch submitted" "$app_pid"
}

# Stop one slot: everything it started, nothing it did not. Recorded process
# groups first (that is what holds GNOME, KDE and the iosc shell), then any
# process whose argv names the slot, then its bus and rendezvous files.
xs_stop_slot_named() {  # xs_stop_slot_named <slot>
    local slot="${1:?slot}"
    xs_log "stopping slot '$slot'"
    xs_reap_slot_session_pgroups "$slot"
    xs_reap_slot_named_processes "$slot"
    xs_reap_slot_pidfiles "$slot"
    xs_remove_slot_state "$slot"
    xs_log "slot $slot stopped"
}

# stop             the non-slot session; the Xios app goes with it only when no
#                  slot is left to show
# stop all         every slot, the non-slot session, shared services, the Xios app
# --slot X stop    just that slot
xios_session_stop() {
    local scope="${1:-}" slot live=""
    xs_write_status stop stopping "stopping session"
    if [ -n "$XS_SLOT" ]; then
        xs_stop_slot_named "$XS_SLOT"
        xs_write_status stop stopped "slot stopped: $XS_SLOT"
        return 0
    fi
    case "$scope" in
        all|--all)
            for slot in $(xs_known_slots); do
                [ "$slot" = "$XS_SLOT" ] && continue
                xs_stop_slot_named "$slot"
            done
            xios_session_teardown "-> stop all" 1 1
            xs_clear_active
            xs_log "all sessions stopped; Xios app killed, back to SpringBoard."
            xs_write_status stop stopped "all sessions stopped"
            return 0 ;;
    esac
    for slot in $(xs_known_slots); do
        xs_slot_has_live_process "$slot" && live="$live $slot"
    done
    if [ -n "$live" ]; then
        # Desktops are still running in slots: keep the display app and the shared
        # audio services for them.
        xios_session_teardown "-> stop" 0 0
        xs_clear_active
        xs_log "session stopped; slots still running:$live (Xios app left up)."
        xs_write_status stop stopped "session stopped; slots still running:$live"
    else
        xios_session_teardown "-> stop" 1 1
        xs_clear_active
        xs_log "session stopped; Xios app killed, back to SpringBoard."
        xs_write_status stop stopped "all sessions stopped"
    fi
}

xios_session_resize() {
    local owner
    owner="$(cat "$XS_ACTIVE" 2>/dev/null || true)"
    case "$owner" in
        iosc|mutter|gnome|kde|kde-desktop|kde-nano|kde-mobile)
            xs_log "resize: restarting active preset '$owner' with requested display settings"
            # A slot refuses to replace its own display, so stop it first.
            [ -n "$XS_SLOT" ] && xs_stop_slot_named "$XS_SLOT"
            xios_session_run_unlocked "$owner"
            ;;
        ""|stop)
        xs_log "resize: no active desktop; starting iosc"
            xios_session_run_unlocked iosc
            ;;
        *)
            xs_log "ERROR: cannot resize unknown active session '$owner'"
            xs_write_status resize error "unknown active session: $owner"
            return 2
            ;;
    esac
}

# ---------------------------------------------------------------------------
# dispatcher — the ONE entry point the CLI and daemon call.
#   xios_session_run <preset> [arg]
# ---------------------------------------------------------------------------
xios_session_run_unlocked() {
    local preset="$1"; shift 2>/dev/null || true
    case "$preset" in
        iosc)        xios_session_iosc ;;
        mutter)      xios_session_mutter ;;
        gnome)       xios_session_gnome ;;
        kde|plasma)                            xios_session_kde xios ;;
        kde-desktop|plasma-desktop)            xios_session_kde desktop ;;
        kde-nano|plasma-nano|nano)             xios_session_kde nano ;;
        kde-mobile|plasma-mobile|mobile)       xios_session_kde mobile ;;
        app)         xios_session_app "${1:-}" ;;
        resize|display) xios_session_resize ;;
        stop|off)    xios_session_stop "${1:-}" ;;
        ""|help|-h|--help)
            cat >&2 <<EOF
xios-session presets:
  iosc            iosc compositor + wallpaper + panel (works today)
  mutter          raw Mutter 46 --wayland (flat stage, no shell yet)
  gnome           GNOME session + Shell
  kde             KWin + desktop plasmashell nested on iosc (EXPERIMENTAL)
  kde-nano        KWin + Plasma Nano shell package (EXPERIMENTAL)
  kde-mobile      KWin + Plasma Mobile shell package (EXPERIMENTAL)
  app <name>      launch a client (kgx|gnome-text-editor|gnome-calculator|<exec>)
                  against the running compositor
  resize          restart the active desktop with XIOS_SESSION_WIDTH/HEIGHT/DPI
  stop            stop the non-slot desktop (the display app stays while slots run)
  stop all        stop every slot and the non-slot desktop, back to SpringBoard
  --slot NAME ... run any preset as its own desktop slot; --slot NAME stop stops only it
EOF
            return 2 ;;
        *)
            xs_log "ERROR: unknown preset '$preset'"
            xs_write_status "$preset" error "unknown preset"
            return 2 ;;
    esac
}

# Regenerate the iOS-app desktop entries so apps installed since the last
# session show up in the launcher. Fire-and-forget on purpose: a launcher-menu
# nicety must never delay or fail a session start, so this is backgrounded, its
# output goes to a log, and every failure is swallowed. A warm run is a no-op
# (it rewrites nothing when the entries are current). XIOS_IOS_APP_ENTRIES=0
# skips it.
xs_refresh_ios_app_entries() {
    case "${XIOS_IOS_APP_ENTRIES:-1}" in
        0|no|NO|false|FALSE|off|OFF) return 0 ;;
    esac
    local helper
    for helper in \
        "${XIOS_IOS_APPS_BIN:-}" \
        "$XS_BIN/xios-ios-apps" \
        "$XS_LIBEXEC_DIR/xios-ios-apps"; do
        [ -n "$helper" ] && [ -x "$helper" ] || continue
        nohup "$helper" refresh --quiet \
            >>"$XS_TMP/xios-ios-apps.log" 2>&1 </dev/null &
        disown 2>/dev/null || true
        return 0
    done
    return 0
}

xios_session_run() {
    local preset="${1:-}" rc
    case "$preset" in
        ""|help|-h|--help)
            xios_session_run_unlocked "$@"
            return $? ;;
        app)
            # A client launch must never serialize compositor switches. Some GUI
            # launchers keep their invoking shell alive even after nohup, which used
            # to pin the global lock and make every in-app desktop request wait up to
            # 45 seconds. A concurrent switch may make this one client fail to map;
            # that is preferable to freezing the desktop control plane.
            xios_session_run_unlocked "$@"
            return $? ;;
    esac
    xs_apply_requested_logical
    if xs_switch_request_preset "$preset"; then
        xs_mark_latest_switch_request "$preset"
    fi
    xs_acquire_session_lock "$preset" || return $?
    trap 'xs_release_session_lock' EXIT HUP INT TERM
    xs_sweep_stale_slot_registry
    xs_refresh_ios_app_entries
    xios_session_run_unlocked "$@"
    rc=$?
    xs_release_session_lock
    trap - EXIT HUP INT TERM
    return "$rc"
}
