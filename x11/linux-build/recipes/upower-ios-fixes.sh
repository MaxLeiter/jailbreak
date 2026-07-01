#!/usr/bin/env bash
# upower iOS source-port fixes (idempotent). We build ONLY libupower-glib (the client library)
# because gnome-shell statically imports gi://UPowerGlib in status/system.js at panel boot, so
# the shell will not start without the UPowerGlib typelib + dylib. The upower daemon (src/) is
# Linux-only (udev/systemd/sysfs power_supply) and is dropped; the client library is a GDBus
# proxy needing only glib/gio. Introspection is off here; the UPowerGlib-1.0 typelib is
# generated ON-DEVICE (the St/Shell/AccountsService pattern). Runtime battery data would come
# from an org.freedesktop.UPower daemon we do not ship, so the power indicator degrades to
# "no device" - but the shell boots.
#
# Usage: upower-ios-fixes.sh <upower-src-dir>
set -euo pipefail
SRC="${1:?usage: $0 <upower-src-dir>}"
M="$SRC/meson.build"

# Drop the daemon + packaging subdirs (keep po/dbus/libupower-glib). The client lib does not
# depend on any of them.
for d in etc rules src tools doc; do
  sed -i "/^subdir('$d')\$/d" "$M"
done

# verification
fail=0
for d in src tools; do
  grep -q "^subdir('$d')" "$M" && { echo "!! VERIFY FAILED: subdir('$d') still present"; fail=1; }
done
grep -q "^subdir('libupower-glib')" "$M" || { echo "!! VERIFY FAILED: libupower-glib subdir missing"; fail=1; }
[ "$fail" = 0 ] && echo "upower-ios-fixes: applied + verified (client-lib-only)" || exit 1
