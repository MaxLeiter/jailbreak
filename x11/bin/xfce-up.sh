#!/usr/bin/env bash
# xfce-up.sh — bring up an XFCE 4.16 *session* on an X server that is ALREADY running.
# Runs ON THE DEVICE:
#   ssh root@ipad 'bash -s' < bin/xfce-up.sh        (or scp + run)
#
# Layering (deliberate — see docs/lightde-plan.md):
#   * The X SERVER is started separately: apps/Xios/xios-server.sh (IOSurface, :3) or
#     apps/Xios/x11-server.sh (Xvfb debug/headless). This script does NOT start an X server
#     and will refuse to run if one isn't up on $DISP.
#   * Those server scripts also launch a throwaway fluxbox + demo clients. We take the
#     screen over cleanly with `xfwm4 --replace` rather than duplicating WM/X logic.
#   * We start the per-session D-Bus bus (xfconfd is D-Bus-activated from it) and the
#     core XFCE components. xfce4-session is intentionally skipped for first bring-up;
#     drive the parts directly, wire the session manager in once this is proven.
set -u
export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:$PATH
export HOME=/var/root
[ -r /var/jb/etc/profile.d/xios.sh ] && . /var/jb/etc/profile.d/xios.sh
[ -r /var/jb/etc/profile.d/xios-audio.sh ] && . /var/jb/etc/profile.d/xios-audio.sh

DISP="${DISP:-:3}"
DNUM="${DISP#:}"
TMP=/var/jb/tmp
alive(){ ps ax 2>/dev/null | grep -v grep | grep -q "$1"; }

# --- require an X server on $DISP (do NOT start one) -------------------------
if ! ps ax | grep -v grep | grep -qE "X(ios|vfb|vnc) ${DISP}( |\$)" \
   && [ ! -S "/tmp/.X11-unix/X${DNUM}" ] && [ ! -S "$TMP/.X11-unix/X${DNUM}" ]; then
  echo "!! No X server detected on $DISP."
  echo "   Start one first, e.g.:  bash apps/Xios/xios-server.sh   (IOSurface, $DISP)"
  echo "                      or:  bash apps/Xios/x11-server.sh     (Xvfb debug/headless)"
  exit 1
fi

export DISPLAY="$DISP" XAUTHORITY=/var/root/.Xauthority

# --- XDG environment (so dbus finds service files + apps find .desktop/icons) -
: "${XDG_DATA_DIRS:=/var/jb/usr/share:/var/jb/usr/local/share}"
: "${XDG_CONFIG_DIRS:=/var/jb/etc/xdg}"
: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_CACHE_HOME:=$HOME/.cache}"
: "${XDG_RUNTIME_DIR:=/var/jb/var/run/xfce-${DNUM}}"
export XDG_DATA_DIRS XDG_CONFIG_DIRS XDG_CONFIG_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR
mkdir -p "$XDG_RUNTIME_DIR" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" /var/jb/var/lib/dbus
chmod 0700 "$XDG_RUNTIME_DIR" 2>/dev/null
command -v xios_prepare_runtime_dirs >/dev/null 2>&1 && xios_prepare_runtime_dirs
command -v xios_load_xresources >/dev/null 2>&1 && xios_load_xresources
command -v xios_audio_start >/dev/null 2>&1 && xios_audio_start

# --- kill the previous XFCE session WE started (scoped to this display) -------
# Kill by recorded PID only — never a global pkill (would nuke another session).
PIDFILE="$TMP/.xfce-clients-${DNUM}.pids"
if [ -f "$PIDFILE" ]; then
  while read -r pid; do [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null; done < "$PIDFILE"
  rm -f "$PIDFILE"
fi
: > "$PIDFILE"
spawn(){ # spawn <name> <cmd...> : launch, record PID, report
  local name="$1"; shift
  nohup "$@" >"$TMP/xfce-${name}.log" 2>&1 & echo $! >> "$PIDFILE"
  sleep 1
  echo -n "   $name: "; alive "$name" && echo "up" || { echo "DIED"; tail -3 "$TMP/xfce-${name}.log" | sed 's/^/      /'; }
}

# --- 1. session D-Bus bus ----------------------------------------------------
# machine-id is required by dbus/GLib; create once (idempotent).
dbus-uuidgen --ensure=/var/jb/var/lib/dbus/machine-id 2>/dev/null
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  eval "$(dbus-launch --sh-syntax)"            # exports ADDRESS + PID
  echo "$DBUS_SESSION_BUS_PID" >> "$PIDFILE"   # tear the bus down on next run
fi
echo "==> session bus: ${DBUS_SESSION_BUS_ADDRESS:-<none>}"
#   xfconfd auto-starts on first xfconf access via
#   $XDG_DATA_DIRS/dbus-1/services/org.xfce.Xfconf.service

# --- 2. settings daemon, WM (replace fluxbox), shell -------------------------
echo "==> launching XFCE session on $DISP"
spawn xfsettingsd xfsettingsd                 # theme/dpi/keyboard from xfconf
spawn xfwm4       xfwm4 --replace             # take the screen from fluxbox
spawn xfce4-panel xfce4-panel
spawn xfdesktop   xfdesktop
# xfce4-appfinder is launched on demand (type-to-find launcher), not autostarted.

echo
echo "==> XFCE up on $DISP. Open the Xios app on the iPad to see the desktop."
echo "    launch apps with:  DISPLAY=$DISP xfce4-appfinder    (or from the panel/menu)"
echo "    logs: $TMP/xfce-*.log   |   stop: kill the PIDs in $PIDFILE"

# ---------------------------------------------------------------------------
# One-time setup (after the XFCE debs are published to the repo):
#   apt-get install -y xfce4            # the metapackage (packages/xfce4) -> the 15 debs
#   apt-get install -y x11-fonts-sf     # San Francisco as the default X11 font
# Then: start the X server (xios-server.sh), then run this script.
