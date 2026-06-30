# Xios rootless desktop defaults. POSIX-sh compatible; safe for interactive
# shells and launch scripts. Explicit user-provided environment always wins.

case ":$PATH:" in
  *:/var/jb/usr/bin:*) ;;
  *) PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:$PATH ;;
esac
export PATH

: "${HOME:=/var/root}"
: "${USER:=root}"
: "${LOGNAME:=$USER}"
: "${SHELL:=/var/jb/bin/sh}"
: "${TERM:=xterm-256color}"
: "${LANG:=en_US.UTF-8}"
: "${LC_CTYPE:=UTF-8}"
: "${NO_AT_BRIDGE:=1}"
: "${XDG_DATA_DIRS:=/var/jb/usr/share:/var/jb/usr/local/share}"
: "${XDG_CONFIG_DIRS:=/var/jb/etc/xdg}"
: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_CACHE_HOME:=$HOME/.cache}"
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
  xios_uid="$(id -u 2>/dev/null || echo 0)"
  XDG_RUNTIME_DIR="/var/jb/var/run/user/$xios_uid"
  unset xios_uid
fi
export HOME USER LOGNAME SHELL TERM LANG LC_CTYPE NO_AT_BRIDGE
export XDG_DATA_DIRS XDG_CONFIG_DIRS XDG_CONFIG_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR

# Native iPad 7 profile by default. Override with:
#   XIOS_DISPLAY_PROFILE=comfy  # 1440x1080 @176 dpi
#   XIOS_DISPLAY_PROFILE=debug  # 1024x768 @96 dpi
# Or set W/H/DPI/GEOM directly before launching.
: "${XIOS_DISPLAY_PROFILE:=native}"
xios_apply_display_profile() {
  case "${XIOS_DISPLAY_PROFILE:-native}" in
    comfy)
      : "${W:=1440}"; : "${H:=1080}"; : "${DPI:=176}" ;;
    debug|vnc)
      : "${W:=1024}"; : "${H:=768}"; : "${DPI:=96}" ;;
    native|retina|*)
      : "${W:=2160}"; : "${H:=1620}"; : "${DPI:=264}" ;;
  esac
  : "${GEOM:=${W}x${H}}"
  export W H DPI GEOM
}

xios_prepare_runtime_dirs() {
  mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" \
    /var/jb/var/lib/xkb /var/jb/tmp/.X11-unix /var/jb/var/tmp 2>/dev/null || true
  chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
  chmod 1777 /var/jb/tmp/.X11-unix /var/jb/var/tmp 2>/dev/null || true
}

xios_load_xresources() {
  if [ -n "${DISPLAY:-}" ] && command -v xrdb >/dev/null 2>&1 \
     && [ -r /var/jb/etc/X11/Xresources/xios ]; then
    xrdb -merge /var/jb/etc/X11/Xresources/xios >/dev/null 2>&1 || true
  fi
  if [ -n "${DISPLAY:-}" ] && command -v xset >/dev/null 2>&1; then
    xset b off >/dev/null 2>&1 || true
    xset r rate 350 40 >/dev/null 2>&1 || true
  fi
  if [ -n "${DISPLAY:-}" ] && command -v xsetroot >/dev/null 2>&1; then
    xsetroot -cursor_name left_ptr >/dev/null 2>&1 || true
  fi
}
