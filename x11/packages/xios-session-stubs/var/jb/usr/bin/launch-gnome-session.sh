#!/bin/sh
# launch-gnome-session.sh — bring up a GNOME session under Mutter/MetaBackendIOS on iOS.
#
# Starts the freedesktop stub daemons (login1/polkit/accounts) and gnome-session inside ONE
# private session bus, then gnome-session (classic non-systemd path) starts gnome-shell, which
# brings up Mutter/MetaBackendIOS and the Xios rendezvous server. See the gnome-session plan in
# the Xios docs for the full rationale (the shared-bus ordering is the one fiddly part).
set -e
PREFIX=/var/jb/usr
LIBEXEC=$PREFIX/libexec

# 1. runtime dir + env
export XDG_RUNTIME_DIR=/var/jb/tmp/xios-run
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
export WAYLAND_DISPLAY=wayland-0
unset DISPLAY
export GDK_BACKEND=wayland CLUTTER_BACKEND=wayland
export XDG_SESSION_TYPE=wayland XDG_CURRENT_DESKTOP=GNOME XDG_SESSION_CLASS=user
export XDG_DATA_DIRS=$PREFIX/share:/var/jb/usr/local/share
export GSETTINGS_SCHEMA_DIR=$PREFIX/share/glib-2.0/schemas
export DYLD_LIBRARY_PATH=$PREFIX/lib:$PREFIX/lib/mutter-14:/var/jb/lib/angle

# 2. write the custom session (org.gnome.Shell only for first boot) into XDG_CONFIG_DIRS
CFG=$XDG_RUNTIME_DIR/xdg
mkdir -p "$CFG/gnome-session/sessions"
cat > "$CFG/gnome-session/sessions/xios.session" <<EOF
[GNOME Session]
Name=Xios GNOME
RequiredComponents=org.gnome.Shell;
EOF
export XDG_CONFIG_DIRS=$CFG:/var/jb/etc/xdg

# 3+4. ONE bus for everything. login1/PolicyKit1/Accounts/UPower are normally SYSTEM-bus
#      services, but under dbus-run-session there is only a session bus. Point
#      DBUS_SYSTEM_BUS_ADDRESS at it so clients asking for G_BUS_TYPE_SYSTEM meet the stubs,
#      then run the stubs + gnome-session inside the one dbus-run-session.
#      xios-hwbridged (from the xios-fhs hardware bridge, if installed) claims
#      org.freedesktop.UPower there too — battery/AC backed by IOKit — so the shell's
#      battery indicator and gsd-power light up.
exec dbus-run-session -- sh -c '
  export DBUS_SYSTEM_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS"
  '"$LIBEXEC"'/xios-login1-stub &
  '"$LIBEXEC"'/xios-polkit-stub &
  '"$LIBEXEC"'/xios-accounts-stub &
  [ -x '"$LIBEXEC"'/xios-hwbridged ] && '"$LIBEXEC"'/xios-hwbridged &
  sleep 1   # let the stubs claim their names before the shell queries them
  exec gnome-session --builtin --session=xios
'
