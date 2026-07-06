#!/usr/bin/env bash
# xios-session-lib.sh — the session-launcher core (sourced, never run directly).
#
# One place that knows how to (1) tear down whatever desktop session is currently
# on the iPad and (2) bring up a chosen one, then relaunch the Xios display app.
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
# (gotcha a: kill ALL of iosc/mutter/gnome/KDE/Xios/panels/clients + rm every
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
#
# JETSAM NOTE (why the settle exists): switching flavors kills the old compositor
# (which holds a large GPU IOSurface + Metal/ANGLE context, ~30MB) and starts a new
# one that allocates its own surface + context. Doing that back-to-back spikes GPU
# memory and iOS jetsams the foreground Xios app mid-transition. So the presets:
# tear down (kill old compositor + the app so it isn't holding stale GPU state),
# SETTLE (let the kernel reclaim the old surface), THEN start the new compositor,
# then relaunch the display once the new surface exists. Status is updated at every
# step so the picker shows what's happening instead of going dark.
#
# Status "state" vocabulary (xios-session-status.json):
#   stopping | starting | waiting | relaunching | up | error | stopped | compositor-only

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
XS_SLOT_REGISTRY_DIR="${XS_SLOT_REGISTRY_DIR:-$XS_TMP/xios-displays.d}"
if [ -n "$XS_SLOT" ]; then
    export XIOS_SESSION_SLOT="$XS_SLOT"
    if [ "$XS_STATUS" = "$XS_TMP/xios-session-status.json" ]; then
        XS_STATUS="$XS_TMP/xios-session-$XS_SLOT.json"
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
    XS_KWIN_SOCKET="${XS_KWIN_SOCKET:-kwin-$XS_SLOT}"
    XS_IOSC_LOG="${XS_IOSC_LOG:-$XS_TMP/iosc-$XS_SLOT.log}"
    XS_KDE_LOG="${XS_KDE_LOG:-$XS_TMP/kde-plasma-$XS_SLOT.log}"
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
    XS_KWIN_SOCKET="${XS_KWIN_SOCKET:-kwin-ios-test}"
    XS_IOSC_LOG="${XS_IOSC_LOG:-$XS_TMP/iosc.log}"
    XS_KDE_LOG="${XS_KDE_LOG:-$XS_TMP/kde-plasma.log}"
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

xs_reap_pgid() {
    local pgid="$1" label="${2:-recorded session}"
    local current
    current="$(xs_current_pgid)"
    case "$pgid" in ""|*[!0-9]*|0|1) return 0 ;; esac
    [ -n "$current" ] && [ "$pgid" = "$current" ] && return 0
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
    local busdir="$1" sock addr
    sock="$busdir/session-bus"
    addr="unix:path=$sock"
    mkdir -p "$busdir"; chmod 0700 "$busdir"
    if [ -S "$sock" ]; then
        printf '%s' "$addr"
        return 0
    fi
    [ -x "$XS_DBUS_DAEMON" ] || return 1
    rm -f "$sock"
    "$XS_DBUS_DAEMON" --session --fork --address="$addr" --print-address >/dev/null 2>&1 || return 1
    if [ -S "$sock" ]; then
        printf '%s' "$addr"
        return 0
    fi
    return 1
}

xs_helper_running() {  # xs_helper_running <process-name>
    ps ax 2>/dev/null | grep -v grep | grep -q "$1"
}

xs_start_native_helper() {  # xs_start_native_helper <binary> <log> <busdir> <bus_addr>
    local bin="$1" log="$2" busdir="$3" bus_addr="$4" name
    [ -x "$bin" ] || return 0
    name="${bin##*/}"
    xs_helper_running "$name" && return 0
    nohup env \
        XDG_RUNTIME_DIR="$busdir" \
        DBUS_SESSION_BUS_ADDRESS="$bus_addr" \
        DBUS_SYSTEM_BUS_ADDRESS="$bus_addr" \
        XIOS_HWBRIDGE_BUS=session \
        PULSE_SERVER="${PULSE_SERVER:-unix:$XS_TMP/pulse/native}" \
        PULSE_RUNTIME_PATH="${PULSE_RUNTIME_PATH:-$XS_TMP/pulse}" \
        GSETTINGS_BACKEND=memory \
        HOME="$XS_VAR/root" \
        PATH="$XS_BIN:$XS_PREFIX/bin:$XS_PREFIX/sbin${XS_JB:+:$XS_JB/bin:$XS_JB/sbin}:/usr/bin:/bin:$PATH" \
        "$bin" >"$log" 2>&1 </dev/null &
}

xs_start_native_helpers() {  # xs_start_native_helpers <busdir> <bus_addr>
    local busdir="$1" bus_addr="$2" profile
    [ -n "$bus_addr" ] || return 0
    profile="$XS_JB/etc/profile.d/xios-pulse.sh"
    [ -r "$profile" ] && . "$profile" && xios_pulse_start
    xs_start_native_helper "$XS_PREFIX/libexec/xios-hwbridged" "$XS_TMP/xios-hwbridged.log" "$busdir" "$bus_addr"
    xs_start_native_helper "$XS_PREFIX/libexec/xios-sensord" "$XS_TMP/xios-sensord.log" "$busdir" "$bus_addr"
    xs_start_native_helper "$XS_PREFIX/libexec/xios-sysintd" "$XS_TMP/xios-sysintd.log" "$busdir" "$bus_addr"
}

# xs_write_status <preset> <state> <message>
#   state = starting | up | error | stopped   (the app / CLI can poll this)
xs_write_status() {
    local preset="$1" state="$2" msg="$3"
    local at active width height stride display ddx socket input_socket meta="" extra=""
    at="$(date '+%Y-%m-%dT%H:%M:%S')"
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
        printf '{"slot":"%s","preset":"%s","state":"%s","message":"%s","at":"%s","wayland":"%s","json":"%s","status":"%s"%s}\n' \
            "$(xs_json_escape "$XS_SLOT")" "$(xs_json_escape "$preset")" \
            "$(xs_json_escape "$state")" "$(xs_json_escape "$msg")" "$at" \
            "$(xs_json_escape "$XS_WAYLAND_NAME")" "$(xs_json_escape "$XS_CONFIG_JSON")" \
            "$(xs_json_escape "$XS_STATUS")" "$extra" >"$XS_SLOT_REGISTRY" 2>/dev/null || true
    fi
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
    local preset="${1:-session}" pgid
    pgid="$(xs_current_pgid)"
    case "$pgid" in ""|*[!0-9]*|0|1) return 0 ;; esac
    printf '%s\t%s\t%s\t%s\n' "$pgid" "$preset" "${XS_SLOT:-}" "$(date '+%Y-%m-%dT%H:%M:%S')" >>"$XS_SESSION_PGIDS" 2>/dev/null || true
}

xs_reap_recorded_session_pgroups() {
    [ -f "$XS_SESSION_PGIDS" ] || return 0
    local pgid preset slot at current
    current="$(xs_current_pgid)"
    while IFS=$'\t' read -r pgid preset slot at; do
        case "$pgid" in ""|*[!0-9]*|0|1) continue ;; esac
        [ -n "$current" ] && [ "$pgid" = "$current" ] && continue
        xs_reap_pgid "$pgid" "previous ${preset:-session}"
    done <"$XS_SESSION_PGIDS"
    rm -f "$XS_SESSION_PGIDS" 2>/dev/null || true
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
        if [ "$slot" = "$want" ]; then
            [ -n "$current" ] && [ "$pgid" = "$current" ] && continue
            xs_reap_pgid "$pgid" "slot $want ${preset:-session}"
        else
            printf '%s\t%s\t%s\t%s\n' "$pgid" "$preset" "$slot" "$at" >>"$tmp" 2>/dev/null || true
        fi
    done <"$XS_SESSION_PGIDS"
    mv "$tmp" "$XS_SESSION_PGIDS" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
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
# teardown (gotcha a) — kill every compositor/app/client + rm every stale socket
# ---------------------------------------------------------------------------
# Union of the teardown greps in the compositor/app bring-up scripts, anchored
# to binary paths so it never matches this script itself
# (xios-session) or our own shell. We additionally exclude $$ and
# the parent pid as belt-and-braces.
xs_kill_pattern='Xios :| Xios$|/Xios\.app/Xios|/bin/iosc( |$)|/bin/iosc-|ioscbar|ioscdock|ioscoverview|ioscbg|run-kde-plasma\.sh|/usr/bin/mutter|/usr/bin/gnome-shell|gnome-session|kwin_wayland|plasmashell|plasmawindowed|kactivitymanagerd|/bin/kgx|gnome-text-editor|gnome-calculator|xios-a11yd|xios-audiod|xios-mediad|xios-sysintd|dbus-daemon.*--session|dbus-run-session|pactl (info|set-sink-volume xios)|paplay .*xios|mpv --player-operation-mode=pseudo-gui'

xios_session_teardown() {
    local why="${1:-switching sessions}"
    xs_log "teardown ($why): killing compositors + apps + clients"
    xs_reap_recorded_session_pgroups
    local self=$$ parent=$PPID pid pids
    pids="$(
        ps ax 2>/dev/null | grep -v grep | grep -E "$xs_kill_pattern" \
            | awk '{print $1}' \
            | while read -r pid; do
                [ -z "$pid" ] && continue
                [ "$pid" = "$self" ] && continue
                [ "$pid" = "$parent" ] && continue
                printf '%s\n' "$pid"
            done
    )"
    for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
    sleep 1
    pids="$(
        {
            printf '%s\n' $pids
            ps ax 2>/dev/null | grep -v grep | grep -E "$xs_kill_pattern" | awk '{print $1}'
        } | awk '!seen[$1]++'
    )"
    for pid in $pids; do
        [ -z "$pid" ] && continue
        [ "$pid" = "$self" ] && continue
        [ "$pid" = "$parent" ] && continue
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    done
    # rm every stale rendezvous/socket file (gotcha a). Globs cover iosc-ddx,
    # mutter-ddx, xios-ddx and every *-input.sock; explicit names cover the rest.
    rm -f "$XS_WAYLAND_SOCK" "$XS_WAYLAND_SOCK.lock" \
          "$XS_TMP/xios.json" \
          "$XS_TMP/xios-a11y.sock" \
          "$XS_TMP"/*-ddx.sock \
          "$XS_TMP"/*-input.sock \
          "$XS_TMP/kwin-ios-test" "$XS_TMP/kwin-ios-test.lock" \
          "$XS_TMP/kde-session-bus" \
          "$XS_TMP/iosc-wm.sock" \
          "$XS_TMP/iosc-native.sock" 2>/dev/null || true
    rm -rf "$XS_TMP/xios-session-bus" 2>/dev/null || true
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
    "$XS_UIOPEN" -b "$XS_XIOS_BUNDLE" 2>/dev/null \
        || "$XS_UIOPEN" "$XS_XIOS_BUNDLE" 2>/dev/null || true
}

xs_wait_socket() {  # xs_wait_socket <path> <tries>
    local p="$1" n="${2:-40}" i=0
    while [ ! -S "$p" ] && [ "$i" -lt "$n" ]; do sleep 0.2; i=$((i+1)); done
    [ -S "$p" ]
}

# Let the kernel reclaim the old compositor's GPU IOSurface + context before the
# next compositor allocates, so the two don't co-reside and jetsam the app. Runs
# AFTER teardown (which already killed the old compositor + the app). Tunable.
xs_settle() {
    local s="${XIOS_SESSION_SETTLE:-2}"
    xs_log "settling ${s}s (freeing the old GPU surface before the next compositor allocates)"
    sleep "$s"
}

# Make sure the Xios display app is up after the new compositor exists. If it's
# alive, just bring it forward; if teardown killed it (it did) or iOS jetsammed it
# during bring-up, relaunch it and mark the status "relaunching display".
xs_ensure_xios() {  # xs_ensure_xios <preset>
    local preset="${1:-session}"
    if pgrep -f "Xios.app/Xios" >/dev/null 2>&1; then
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
    # run-shell.sh starts the compositor because teardown removed the socket. Pass
    # through the tunables it honours: IOSC_LOGICAL (desktop size) and, since
    # iosc-shell 0.9.3, IOSC_PANEL_OPACITY (0-100; the panel is 85% translucent by
    # default). Only export opacity when the caller set it, so an unset value never
    # overrides the panel's own default.
    export IOSC_LOGICAL="${IOSC_LOGICAL:-1440x1080}"
    export WAYLAND_DISPLAY="$XS_WAYLAND_NAME"
    export XIOS_JSON_PATH="$XS_CONFIG_JSON"
    export IOSC_DDX_SOCK="$XS_IOSC_DDX_SOCK"
    export IOSC_INPUT_SOCK="$XS_IOSC_INPUT_SOCK"
    export IOSC_CLIPBOARD_SOCK="$XS_IOSC_CLIPBOARD_SOCK"
    export IOSC_WM_SOCK="$XS_IOSC_WM_SOCK"
    export IOSC_LOG="$XS_IOSC_LOG"
    [ -n "$XS_SLOT" ] && export IOSC_IGNORE_ACTIVE_SESSION=1
    [ -n "${IOSC_PANEL_OPACITY:-}" ] && export IOSC_PANEL_OPACITY
    sh "$script" || true
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
    MUTTER_LOG="${XS_TMP}/mutter${XS_SLOT:+-$XS_SLOT}.log" \
    bash "$script" || true
    xs_ensure_xios mutter   # relaunch the display if it got jetsammed during bring-up
    if [ -f "$XS_CONFIG_JSON" ]; then
        xs_log "mutter up (flat clutter stage; no shell yet)."
        xs_write_status mutter up "mutter --wayland running"
    else
        xs_log "ERROR: mutter did not write xios.json (see $XS_TMP/mutter.log)"
        xs_write_status mutter error "mutter failed; see mutter.log"; return 1
    fi
}

# gnome: teardown, then launch-gnome-session.sh from xios-session-stubs. That
# launcher re-signs gnome-shell, starts the freedesktop/iOS bridge shims on one
# private session bus, then runs gnome-session --builtin --session=xios so
# gnome-session owns org.gnome.Shell.
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
    GNOME_SHELL_LOG="${XS_TMP}/gnome-shell${XS_SLOT:+-$XS_SLOT}.log" \
    XIOS_SESSION_SLOT="$XS_SLOT" \
    bash "$script" || true
    xs_ensure_xios gnome    # relaunch the display if it got jetsammed during bring-up
    xs_write_status gnome waiting "waiting for GNOME Shell to paint"
    # Do NOT gate "gnome up" on xios.json: Mutter writes it BEFORE the gjs shell
    # loads, so it only proves the compositor came up (identical to bare mutter).
    # The real success marker (per gnome-session) is "GNOME Shell started at" in
    # gnome-shell.log, printed only after the JS UI + stage load. Poll for that, a
    # hard failure, or process exit for ~15s; a compositor that never paints the
    # shell is reported distinctly (not as a win).
    local log="$XS_TMP/gnome-shell${XS_SLOT:+-$XS_SLOT}.log" i=0 outcome=timeout
    local fail_re='Failed to load module|couldn.t be found|JS ERROR|Execution of main\.js threw exception|MTLCreateSystemDefaultDevice'
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
    ps ax | grep -v grep | grep -E "$1" >/dev/null 2>&1
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
    xs_log "$preset (experimental): $script"
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
    PLASMA_SHELL_PLUGIN="${plasma_shell_plugin:-${PLASMA_SHELL_PLUGIN-}}" \
    KDE_PLASMA_FLAVOR="$flavor" bash "$script" || true
    xs_ensure_xios "$preset"
    xs_write_status "$preset" waiting "waiting for $label"
    local i=0 kde_failed=0 kde_ready=0
    while [ "$i" -lt 20 ]; do
        if grep -qE "plasmashell exited|kwin exited|KWin did not create|kwin socket did not appear" "$XS_KDE_LOG" 2>/dev/null; then
            kde_failed=1
            break
        fi
        if xios_session_process_running "kwin_wayland" && xios_session_process_running "plasmashell"; then
            kde_ready=1
            break
        fi
        sleep 0.5
        i=$((i+1))
    done
    if [ "$kde_ready" = 1 ]; then
        sleep 0.5
        if ! xios_session_process_running "kwin_wayland" || ! xios_session_process_running "plasmashell"; then
            kde_ready=0
        fi
    fi
    if [ "$kde_ready" = 0 ] && [ "$kde_failed" = 0 ]; then
        if grep -qE "plasmashell exited|kwin exited|KWin did not create|kwin socket did not appear" "$XS_KDE_LOG" 2>/dev/null; then
            kde_failed=1
        fi
    fi
    if [ "$kde_failed" = 1 ]; then
        xs_log "$preset FAILED: shell/compositor exited; see $XS_TMP/kde-plasma.log"
        tail -40 "$XS_KDE_LOG" 2>/dev/null | while IFS= read -r ln; do xs_log "  | $ln"; done
        xs_write_status "$preset" error "$label exited; see kde-plasma.log"
        return 1
    elif [ "$kde_ready" = 1 ]; then
        xs_log "$preset up (kwin-ios-test + plasmashell running)."
        xs_write_status "$preset" up "$label running"
    elif xios_session_process_running "kwin_wayland" || [ -S "$XS_TMP/$XS_KWIN_SOCKET" ]; then
        xs_log "$preset compositor up, but plasmashell is not running; see $XS_TMP/kde-plasma.log"
        xs_write_status "$preset" compositor-only "KWin running; plasmashell not confirmed"
    else
        xs_log "ERROR: KWin is not running; see $XS_TMP/kde-plasma.log"
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
    [ -n "$name" ] || { xs_log "ERROR: 'app' needs a name"; xs_write_status app error "no app name"; return 1; }
    if [ ! -S "$XS_WAYLAND_SOCK" ]; then
        xs_log "ERROR: no compositor running (no $XS_WAYLAND_SOCK). Pick iosc/mutter/gnome first."
        xs_write_status app error "no compositor; start a session first"; return 1
    fi
    xs_write_status "app:$name" starting "launching $name"

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

    local owner busdir="$XS_TMP/xios-session-bus" addr
    local app_runtime="$busdir" app_wayland="$XS_WAYLAND_SOCK"
    local app_env=() client_env=() kv
    if command -v xios_profile_env_pairs >/dev/null 2>&1; then
        while IFS= read -r kv; do
            [ -n "$kv" ] && client_env+=("$kv")
        done < <(xios_profile_env_pairs iosc-client-gpu)
    else
        client_env=(
            GDK_BACKEND=wayland
            GSK_RENDERER=ngl
            QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"
            QT_WAYLAND_DISABLE_WINDOWDECORATION="${QT_WAYLAND_DISABLE_WINDOWDECORATION:-1}"
            ANGLE_REAL_LIBEGL="$XS_ANGLE_LIBEGL"
            GSETTINGS_BACKEND=memory
            LC_CTYPE="${LC_CTYPE:-UTF-8}"
        )
    fi
    xs_log "app: launching '$exec' as a wayland client of the running compositor"
    local a11y_prefix
    a11y_prefix="$(xs_a11y_prefix)"
    local gtk_a11y_env=()
    xs_a11y_enabled || gtk_a11y_env=(GTK_A11Y=none)
    local dbus_addr=()
    owner="$(cat "$XS_ACTIVE" 2>/dev/null || true)"
    case "$owner" in
        kde|kde-desktop|kde-nano|kde-mobile|plasma|plasma-desktop|plasma-nano|plasma-mobile)
            if [ -S "$XS_TMP/$XS_KWIN_SOCKET" ]; then
                app_runtime="$XS_TMP"
                app_wayland="$XS_TMP/$XS_KWIN_SOCKET"
                if command -v xios_profile_env_pairs >/dev/null 2>&1; then
                    while IFS= read -r kv; do
                        [ -n "$kv" ] && app_env+=("$kv")
                    done < <(xios_profile_env_pairs plasma-egl)
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
                local kde_bus_file="$XS_TMP/kde-session-bus${XS_SLOT:+-$XS_SLOT}"
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
        launcher=("$XS_DBUS_RUN" -- "${launcher[@]}")
    fi
    nohup env \
        XDG_RUNTIME_DIR="$app_runtime" \
        WAYLAND_DISPLAY="$app_wayland" \
        "${client_env[@]}" \
        "${app_env[@]}" \
        "${gtk_a11y_env[@]}" \
        "${dbus_addr[@]}" \
        HOME="$XS_VAR/root" \
        "${launcher[@]}" \
        >>"$XS_TMP/xios-session-client.log" 2>&1 </dev/null &
    # bring the shared Xios display forward so the new window is visible
    xs_foreground_xios
    xs_log "app '$name' launched (pid $!). Window maps into the current compositor."
    xs_write_status "app:$name" up "$name launched"
}

# stop: tear everything down and return to SpringBoard.
xios_session_stop() {
    xs_write_status stop stopping "stopping session"
    if [ -n "$XS_SLOT" ]; then
        xs_reap_slot_session_pgroups "$XS_SLOT"
        rm -f "$XS_WAYLAND_SOCK" "$XS_WAYLAND_SOCK.lock" \
              "$XS_CONFIG_JSON" "$XS_IOSC_DDX_SOCK" "$XS_IOSC_INPUT_SOCK" \
              "$XS_IOSC_CLIPBOARD_SOCK" "$XS_IOSC_WM_SOCK" \
              "$XS_MUTTER_DDX_SOCK" "$XS_MUTTER_INPUT_SOCK" \
              "$XS_TMP/$XS_KWIN_SOCKET" "$XS_TMP/$XS_KWIN_SOCKET.lock" 2>/dev/null || true
        rm -f "$XS_SLOT_REGISTRY" 2>/dev/null || true
        xs_log "slot $XS_SLOT stopped"
        xs_write_status stop stopped "slot stopped: $XS_SLOT"
    else
        xios_session_teardown "-> stop"
        xs_clear_active
        xs_log "session stopped; Xios app killed, back to SpringBoard."
        xs_write_status stop stopped "all sessions stopped"
    fi
}

xios_session_resize() {
    local owner
    owner="$(cat "$XS_ACTIVE" 2>/dev/null || true)"
    case "$owner" in
        iosc|mutter|gnome|kde|kde-nano|kde-mobile)
            xs_log "resize: restarting active preset '$owner' with requested display settings"
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
        stop|off)    xios_session_stop ;;
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
  stop            tear everything down, back to SpringBoard
EOF
            return 2 ;;
        *)
            xs_log "ERROR: unknown preset '$preset'"
            xs_write_status "$preset" error "unknown preset"
            return 2 ;;
    esac
}

xios_session_run() {
    local preset="${1:-}" rc
    case "$preset" in
        ""|help|-h|--help)
            xios_session_run_unlocked "$@"
            return $? ;;
    esac
    xs_apply_requested_logical
    if xs_switch_request_preset "$preset"; then
        xs_mark_latest_switch_request "$preset"
    fi
    xs_acquire_session_lock "$preset" || return $?
    trap 'xs_release_session_lock' EXIT HUP INT TERM
    xios_session_run_unlocked "$@"
    rc=$?
    xs_release_session_lock
    trap - EXIT HUP INT TERM
    return "$rc"
}
