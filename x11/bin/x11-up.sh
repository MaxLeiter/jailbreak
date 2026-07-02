#!/usr/bin/env bash
# x11-up.sh — bring up the Phase-0 X-over-VNC session on a rootless Procursus device.
# Captures the working recipe proven in the 2026-06-28 spike (see ../SCOPE.md).
#
# Run ON THE DEVICE, e.g.:
#   ssh root@ipad 'bash -s' < bin/x11-up.sh
#
# Prereqs (one-time, see comments at bottom):
#   - X stack installed from the repo: tigervnc-standalone-server (the rebuilt
#     Xvnc that spawns its xkbcomp helper via /var/jb/bin/sh — no on-device hacks)
#   - at least one font under the rootless font dir (e.g. the x11-fonts-sf package)
set -u

export PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:$PATH
export HOME=/var/root
: "${XIOS_DISPLAY_PROFILE:=comfy}"
[ -r /var/jb/etc/profile.d/xios.sh ] && . /var/jb/etc/profile.d/xios.sh
command -v xios_apply_display_profile >/dev/null 2>&1 && xios_apply_display_profile
command -v xios_prepare_runtime_dirs >/dev/null 2>&1 && xios_prepare_runtime_dirs
export DISPLAY=:1
export XAUTHORITY=$HOME/.Xauthority

# --- config -----------------------------------------------------------------
XVNC="${XVNC:-/var/jb/usr/bin/Xvnc}"     # from the tigervnc-standalone-server package
GEOM="${GEOM:-1024x768}"                  # Xios defaults set comfy/native profiles
DEPTH="${DEPTH:-24}"
DPI="${DPI:-96}"                          # Xios defaults set 176/264 when sourced
PORT="${PORT:-5901}"
XKBDIR=/var/jb/usr/share/X11/xkb
FONT="${FONT:-Courier New}"

alive(){ ps ax 2>/dev/null | grep -v grep | grep -q "$1"; }

# --- writable xkb compile dir ------------------------------------------------
# The X server runs xkbcomp at startup and drops the compiled keymap here. The
# packaged Xvnc already execs that helper via /var/jb/bin/sh (rootless has no
# /bin/sh), so no symlink hack is needed — just make sure the output dir exists.
mkdir -p /var/jb/var/lib/xkb

# --- launch the X/VNC server -------------------------------------------------
pkill -f "$(basename "$XVNC") :1" 2>/dev/null; sleep 1
rm -f /var/jb/tmp/xvnc.log
nohup "$XVNC" :1 -geometry "$GEOM" -depth "$DEPTH" -dpi "$DPI" -rfbport "$PORT" \
  -SecurityTypes None -localhost -AlwaysShared -xkbdir "$XKBDIR" -desktop iPadX11 \
  >/var/jb/tmp/xvnc.log 2>&1 &
sleep 4
if alive "$(basename "$XVNC") :1"; then
  echo "Xvnc up on :1 — $(grep -m1 'Listening' /var/jb/tmp/xvnc.log | sed 's/^ *//')"
else
  echo "Xvnc FAILED to start:"; tail -8 /var/jb/tmp/xvnc.log; exit 1
fi
command -v xios_load_xresources >/dev/null 2>&1 && xios_load_xresources

# --- window manager + a terminal --------------------------------------------
alive fluxbox || nohup fluxbox >/var/jb/tmp/fluxbox.log 2>&1 &
sleep 1
nohup xterm -fa "$FONT" -fs 12 -fg white -bg black >/var/jb/tmp/xterm.log 2>&1 &
sleep 2

echo "Session clients:"
for c in fluxbox xterm; do echo -n "  $c: "; alive "$c" && echo running || echo "DIED"; done
echo
echo "Connect a VNC client to 127.0.0.1:$PORT (tunnel it off-device with:"
echo "  ssh -L $PORT:127.0.0.1:$PORT root@<ipad>   then open vnc://127.0.0.1:$PORT )"

# ---------------------------------------------------------------------------
# One-time setup (now all packaged — no byte-patching or symlink hacks):
#
#   # Add the repo (repo.maxleiter.com) in your package manager, then:
#   apt-get install -y tigervnc-standalone-server fluxbox xterm x11-apps
#   # tigervnc-standalone-server is the rebuilt-from-source Xvnc: it installs
#   # cleanly (the bogus tigervnc-xorg-extension dep is dropped) and already
#   # spawns its xkbcomp helper via /var/jb/bin/sh, so keyboard init works.
#   apt-get install -y x11-fonts-sf   # San Francisco as the default X11 font
#
#   # The clients pull in the rest (xauth, xkbcomp, xkeyboard-config, the X libs,
#   # fontconfig) as dependencies. Nothing else to patch by hand.
