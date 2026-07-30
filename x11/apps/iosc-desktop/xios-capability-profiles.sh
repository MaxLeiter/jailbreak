#!/usr/bin/env bash
# Named runtime capability profiles for Xios desktop processes.
#
# Source this file from launchers to keep render env, entitlement tier, package
# deps, and smoke expectations in one place. Executing it directly provides a
# small inspection/self-test CLI.

set -u

# The installed copy is sourced after xios-session-lib has already resolved
# XS_JB/XS_PREFIX. Only load a build target when this file is run directly from
# the source tree; target-lib.sh is intentionally not part of the runtime
# package.
if [ -z "${XS_PREFIX:-}" ]; then
    _xt="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    while [ "$_xt" != / ] && [ ! -f "$_xt/linux-build/target-lib.sh" ]; do
        _xt="$(dirname "$_xt")"
    done
    if [ -f "$_xt/linux-build/target-lib.sh" ]; then
        . "$_xt/linux-build/target-lib.sh"
        xios_load_target "${XIOS_TARGET:-rootless-1900}"
    else
        _xcp_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [ "${XIOS_PREFIX+x}" != x ]; then
            case "$_xcp_here" in
                */libexec/xios-session)
                    XIOS_PREFIX="${_xcp_here%/libexec/xios-session}"
                    ;;
                /var/jb/*)
                    XIOS_PREFIX=/var/jb
                    ;;
                *)
                    echo "xios-capability-profiles: cannot resolve install prefix" >&2
                    return 1 2>/dev/null || exit 1
                    ;;
            esac
            export XIOS_PREFIX
        fi
    fi
fi

xios_profile_names() {
    printf '%s\n' \
        iosc-client-gpu \
        iosc-platform-gl \
        kde-kwin \
        plasma-egl \
        gtk-wayland \
        xwayland-glamor \
        native-host
}

xios_profile_entitlement() {
    case "${1:-}" in
        iosc-client-gpu)  printf '%s\n' gpu-client ;;
        iosc-platform-gl) printf '%s\n' platform-gl ;;
        kde-kwin)         printf '%s\n' platform-gl ;;
        plasma-egl)       printf '%s\n' platform-gl ;;
        gtk-wayland)      printf '%s\n' gpu-client ;;
        xwayland-glamor)  printf '%s\n' gpu-client ;;
        native-host)      printf '%s\n' platform-iosurface ;;
        *) return 1 ;;
    esac
}

xios_profile_deps() {
    case "${1:-}" in
        iosc-client-gpu)
            printf '%s\n' 'iosc, angle, wayland, xios-session'
            ;;
        iosc-platform-gl)
            printf '%s\n' 'iosc, angle, xios'
            ;;
        kde-kwin)
            printf '%s\n' 'kwin, qt6-wayland, angle, iosc'
            ;;
        plasma-egl)
            printf '%s\n' 'plasma-workspace, plasma-desktop|plasma-mobile|plasma-nano, qt6-wayland, angle'
            ;;
        gtk-wayland)
            printf '%s\n' 'gtk-4, angle, iosc'
            ;;
        xwayland-glamor)
            printf '%s\n' 'xwayland, angle, iosc'
            ;;
        native-host)
            printf '%s\n' 'xios, iosc-host|xios-launcher-tools'
            ;;
        *) return 1 ;;
    esac
}

xios_profile_smoke() {
    case "${1:-}" in
        iosc-client-gpu)
            printf '%s\n' 'client log binds iosc_iosurface; iosc imports client IOSurface'
            ;;
        iosc-platform-gl)
            printf '%s\n' 'iosc log reports ANGLE/Metal renderer and Xios reports iosurface-zerocopy [metal]'
            ;;
        kde-kwin)
            printf '%s\n' 'kwin_wayland creates nested socket; log imports client IOSurfaces without EGL errors'
            ;;
        plasma-egl)
            printf '%s\n' 'QtQuick creates an OpenGL QRhi on ANGLE/Metal and maps fenced IOSurfaces through KWin'
            ;;
        gtk-wayland)
            printf '%s\n' 'GTK4 client uses GSK ngl and maps IOSurface buffers instead of wl_shm fallback'
            ;;
        xwayland-glamor)
            printf '%s\n' 'Xwayland binds iosc_iosurface; iosc imports Xwayland client IOSurfaces'
            ;;
        native-host)
            printf '%s\n' 'host adopts/drains IOSurface and reconnects without zombie surfaces'
            ;;
        *) return 1 ;;
    esac
}

xios_profile_q() {
    # Single-quote for shell eval/export output.
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

xios_profile_export_line() {
    local key="$1" val="$2"
    printf 'export %s=' "$key"
    xios_profile_q "$val"
    printf '\n'
}

xios_profile_unset_line() {
    printf 'unset %s\n' "$1"
}

xios_profile_pair() {
    printf '%s=%s\n' "$1" "$2"
}

xios_profile_env_pairs() {
    local profile="${1:-}"
    local angle prefix jb root_home
    if [ -n "${XS_PREFIX:-}" ]; then
        prefix="$XS_PREFIX"
        jb="${XS_JB:-}"
        root_home="${XS_VAR:-${XS_JB:-}/var}/root"
        angle="${XS_ANGLE_LIBEGL:-${XS_JB:-}/lib/angle/libEGL.angle.dylib}"
    else
        prefix="$XIOS_PREFIX/usr"
        jb="$XIOS_PREFIX"
        root_home="$XIOS_PREFIX/var/root"
        angle="${XS_ANGLE_LIBEGL:-$XIOS_PREFIX/lib/angle/libEGL.angle.dylib}"
    fi
    local lang="${LANG:-C}" lc_ctype="${LC_CTYPE:-UTF-8}" xcomposefile
    case "$lang" in ""|UTF-8|*.UTF-8|*.utf8|C.UTF-8) lang=C ;; esac
    case "$lc_ctype" in ""|C|POSIX|*.UTF-8|*.utf8|C.UTF-8) lc_ctype=UTF-8 ;; esac
    xcomposefile="${XCOMPOSEFILE:-$prefix/share/X11/locale/en_US.UTF-8/Compose}"
    case "$profile" in
        iosc-client-gpu)
            xios_profile_pair XIOS_CAPABILITY_PROFILE "$profile"
            xios_profile_pair GDK_BACKEND wayland
            xios_profile_pair GSK_RENDERER "${IOSC_GSK_RENDERER:-ngl}"
            xios_profile_pair QT_QPA_PLATFORM "${IOSC_QT_QPA_PLATFORM:-wayland-egl}"
            xios_profile_pair QT_WAYLAND_DISABLE_WINDOWDECORATION "${QT_WAYLAND_DISABLE_WINDOWDECORATION:-1}"
            xios_profile_pair ANGLE_REAL_LIBEGL "$angle"
            xios_profile_pair GSETTINGS_BACKEND memory
            xios_profile_pair LANG "$lang"
            xios_profile_pair LC_CTYPE "$lc_ctype"
            xios_profile_pair FC_LANG "${FC_LANG:-en}"
            xios_profile_pair XCOMPOSEFILE "$xcomposefile"
            ;;
        iosc-platform-gl)
            xios_profile_pair XIOS_CAPABILITY_PROFILE "$profile"
            xios_profile_pair XDG_RUNTIME_DIR "${XDG_RUNTIME_DIR:-$XIOS_PREFIX/tmp}"
            xios_profile_pair ANGLE_REAL_LIBEGL "$angle"
            ;;
        kde-kwin)
            xios_profile_pair XIOS_CAPABILITY_PROFILE "$profile"
            xios_profile_pair DYLD_LIBRARY_PATH "$prefix/lib:$jb/lib/angle"
            xios_profile_pair XDG_DATA_DIRS "$prefix/share"
            xios_profile_pair XDG_CONFIG_HOME "${XDG_CONFIG_HOME:-$root_home/.config}"
            xios_profile_pair XDG_CONFIG_DIRS "$jb/etc/xdg:$prefix/etc/xdg"
            xios_profile_pair LANG "$lang"
            xios_profile_pair LC_CTYPE "$lc_ctype"
            xios_profile_pair FC_LANG "${FC_LANG:-en}"
            xios_profile_pair XCOMPOSEFILE "$xcomposefile"
            xios_profile_pair KDE_FULL_SESSION true
            xios_profile_pair KDE_SESSION_VERSION 6
            xios_profile_pair XDG_CURRENT_DESKTOP KDE
            xios_profile_pair XDG_SESSION_TYPE wayland
            xios_profile_pair QT_PLUGIN_PATH "$prefix/lib/qt6/plugins"
            xios_profile_pair QML2_IMPORT_PATH "$prefix/lib/qt6/qml"
            xios_profile_pair QML_IMPORT_PATH "$prefix/lib/qt6/qml"
            xios_profile_pair QSG_RHI_BACKEND "${KWIN_QSG_RHI_BACKEND:-${QSG_RHI_BACKEND:-opengl}}"
            ;;
        plasma-egl)
            xios_profile_pair XIOS_CAPABILITY_PROFILE "$profile"
            xios_profile_pair DYLD_LIBRARY_PATH "$prefix/lib:$jb/lib/angle"
            xios_profile_pair XDG_DATA_DIRS "$prefix/share"
            xios_profile_pair XDG_CONFIG_HOME "${XDG_CONFIG_HOME:-$root_home/.config}"
            xios_profile_pair XDG_CONFIG_DIRS "$jb/etc/xdg:$prefix/etc/xdg"
            xios_profile_pair GSETTINGS_SCHEMA_DIR "$prefix/share/glib-2.0/schemas"
            xios_profile_pair LANG "$lang"
            xios_profile_pair LC_CTYPE "$lc_ctype"
            xios_profile_pair FC_LANG "${FC_LANG:-en}"
            xios_profile_pair XCOMPOSEFILE "$xcomposefile"
            xios_profile_pair KDE_FULL_SESSION true
            xios_profile_pair KDE_SESSION_VERSION 6
            xios_profile_pair XDG_CURRENT_DESKTOP KDE
            xios_profile_pair XDG_SESSION_TYPE wayland
            xios_profile_pair QT_PLUGIN_PATH "$prefix/lib/qt6/plugins"
            xios_profile_pair QML2_IMPORT_PATH "$prefix/lib/qt6/qml"
            xios_profile_pair QML_IMPORT_PATH "$prefix/lib/qt6/qml"
            xios_profile_pair QSG_RHI_BACKEND "${PLASMA_QSG_RHI_BACKEND:-${QSG_RHI_BACKEND:-opengl}}"
            xios_profile_pair QT_QPA_PLATFORM "${PLASMA_QT_QPA_PLATFORM:-wayland-egl}"
            xios_profile_pair QT_WAYLAND_CLIENT_BUFFER_INTEGRATION "${PLASMA_QT_WAYLAND_CLIENT_BUFFER_INTEGRATION:-${QT_WAYLAND_CLIENT_BUFFER_INTEGRATION:-wayland-egl}}"
            xios_profile_pair QT_QUICK_CONTROLS_STYLE "${QT_QUICK_CONTROLS_STYLE:-org.kde.desktop}"
            ;;
        gtk-wayland)
            xios_profile_pair XIOS_CAPABILITY_PROFILE "$profile"
            xios_profile_pair GDK_BACKEND wayland
            xios_profile_pair GSK_RENDERER "${IOSC_GSK_RENDERER:-ngl}"
            xios_profile_pair ANGLE_REAL_LIBEGL "$angle"
            xios_profile_pair GSETTINGS_BACKEND memory
            ;;
        xwayland-glamor)
            xios_profile_pair XIOS_CAPABILITY_PROFILE "$profile"
            xios_profile_pair ANGLE_REAL_LIBEGL "$angle"
            xios_profile_pair XLIB_NO_SHM "${XLIB_NO_SHM:-1}"
            ;;
        native-host)
            xios_profile_pair XIOS_CAPABILITY_PROFILE "$profile"
            xios_profile_pair XIOS_NATIVE_HOST "${XIOS_NATIVE_HOST:-1}"
            xios_profile_pair ANGLE_REAL_LIBEGL "$angle"
            ;;
        *) return 1 ;;
    esac
}

xios_profile_env() {
    local profile="${1:-}" line key val
    xios_profile_env_pairs "$profile" >/dev/null || return 1
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        key="${line%%=*}"
        val="${line#*=}"
        xios_profile_export_line "$key" "$val"
    done <<EOF
$(xios_profile_env_pairs "$profile")
EOF
    case "$profile" in
        kde-kwin) xios_profile_unset_line QT_WAYLAND_CLIENT_BUFFER_INTEGRATION ;;
    esac
}

xios_profile_show() {
    local profile="${1:-}"
    local ent deps smoke
    ent="$(xios_profile_entitlement "$profile")" || return 1
    deps="$(xios_profile_deps "$profile")" || return 1
    smoke="$(xios_profile_smoke "$profile")" || return 1
    printf 'profile=%s\n' "$profile"
    printf 'entitlement=%s\n' "$ent"
    printf 'deps=%s\n' "$deps"
    printf 'smoke=%s\n' "$smoke"
    printf 'env:\n'
    xios_profile_env "$profile" | sed 's/^/  /'
}

xios_profile_self_test() {
    local p count=0
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        xios_profile_entitlement "$p" >/dev/null || return 1
        xios_profile_deps "$p" >/dev/null || return 1
        xios_profile_smoke "$p" >/dev/null || return 1
        xios_profile_env "$p" | grep -q '^\(export\|unset\) ' || return 1
        count=$((count + 1))
    done <<EOF
$(xios_profile_names)
EOF
    [ "$count" -eq 7 ] || return 1
    printf 'xios-capability-profiles: %s profiles ok\n' "$count"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --list)
            xios_profile_names
            ;;
        --show)
            shift
            xios_profile_show "${1:-}" || { echo "unknown profile: ${1:-}" >&2; exit 1; }
            ;;
        --env)
            shift
            xios_profile_env "${1:-}" || { echo "unknown profile: ${1:-}" >&2; exit 1; }
            ;;
        --self-test)
            xios_profile_self_test
            ;;
        -h|--help|"")
            cat <<'EOF'
usage: xios-capability-profiles.sh --list
       xios-capability-profiles.sh --show PROFILE
       xios-capability-profiles.sh --env PROFILE
       xios-capability-profiles.sh --self-test
EOF
            ;;
        *)
            echo "unknown option: $1" >&2
            exit 1
            ;;
    esac
fi
