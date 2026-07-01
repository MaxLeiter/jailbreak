#!/usr/bin/env bash
# gnome-settings-daemon 46 iOS source-port fixes (idempotent) — a MINIMAL gsd for the Xios
# GNOME session. See docs/gnome-session-plan.md for the plugin audit. Rationale:
#
# The gsd CORE daemon (gnome-settings-daemon/) links only gio; all the heavy top-level
# dependencies are consumed ONLY by plugins. We keep the plugins that make sense on a
# Wayland iOS tablet and need no absent hardware/service:
#   KEEP: a11y-settings, housekeeping, keyboard, screensaver-proxy
#   DROP: power (upower/backlight), color (colord/geoclue), datetime (geoclue/gweather/
#         timedated), media-keys (gvc/upower/canberra), sound (canberra/alsa),
#         xsettings (X11-only, no display in a Wayland session), sharing (NetworkManager),
#         print-notifications (CUPS), rfkill, wwan (ModemManager), smartcard (pcsc/gck),
#         wacom (libwacom), usb-protection (USBGuard).
# The dropped plugins are the only consumers of geocode-glib, gweather4, libcanberra-gtk3,
# libgeoclue and upower-glib, so those 5 deps become required:false (never resolved).
# libnotify stays (housekeeping needs it) and is built by recipes/libnotify.mk. gnome-desktop
# is retargeted 3.0 -> 4 (we ship only the GTK4/base library; libcommon + the kept plugins
# use only GTK-independent gnome-desktop API).
#
# Usage: gnome-settings-daemon-ios-fixes.sh <gsd-source-dir>
set -euo pipefail
SRC="${1:?usage: $0 <gsd-src-dir>}"
M="$SRC/meson.build"
P="$SRC/plugins/meson.build"

# --- (1) make the 5 plugin-only heavy deps optional -----------------------------
# geocode-glib: drop the hard geocode-glib-1.0 fallback (make the 2.0 probe non-fatal).
perl -0pi -e "s/^if not geocode_glib_dep\.found\(\)\n  geocode_glib_dep = dependency\('geocode-glib-1\.0', version: '>= 3\.10\.0'\)\nendif\n//m" "$M"
sed -i "s/^gweather_dep = dependency('gweather4')\$/gweather_dep = dependency('gweather4', required: false)/" "$M"
sed -i "s/^libcanberra_gtk_dep = dependency('libcanberra-gtk3')\$/libcanberra_gtk_dep = dependency('libcanberra-gtk3', required: false)/" "$M"
sed -i "s/^libgeoclue_dep = dependency('libgeoclue-2.0', version: '>= 2.3.1')\$/libgeoclue_dep = dependency('libgeoclue-2.0', version: '>= 2.3.1', required: false)/" "$M"
sed -i "s/^upower_glib_dep = dependency('upower-glib', version: '>= 0.99.12')\$/upower_glib_dep = dependency('upower-glib', version: '>= 0.99.12', required: false)/" "$M"

# --- (2) retarget gnome-desktop-3.0 -> gnome-desktop-4 --------------------------
sed -i "s/^gnome_desktop_dep = dependency('gnome-desktop-3.0', version: '>= 3.37.1')\$/gnome_desktop_dep = dependency('gnome-desktop-4', version: '>= 40')/" "$M"

# --- (3) disable the heavy plugins ---------------------------------------------
# Append to disabled_plugins right after it is initialised (idempotent by marker).
if ! grep -q "# iOS: minimal plugin set" "$P"; then
  perl -0pi -e "s/^disabled_plugins = \[\]\n/disabled_plugins = []\n# iOS: minimal plugin set — drop everything that needs absent hardware\/services or X11.\ndisabled_plugins += ['power', 'color', 'datetime', 'media-keys', 'sound', 'xsettings', 'sharing']\n/m" "$P"
fi

# --- (4) neutralize gsd's broken macOS bundle_loader hack ----------------------
# plugins/common/meson.build has an `if host_is_darwin` block that appends a malformed
# ldflag: join_paths() is called with NO arguments (meson errors "join_paths takes at
# least 1 arguments"). It is a half-finished macOS bundle hack and is meaningless here -
# libcommon is a normal static archive linked into the plugin executables. Blank the line.
CM="$SRC/plugins/common/meson.build"
if grep -q "bundle_loader" "$CM"; then
  sed -i '/bundle_loader/c\  # iOS: dropped gsd malformed macOS bundle_loader ldflag (join_paths no-arg).' "$CM"
fi

# --- verification --------------------------------------------------------------
fail=0
check()  { grep -q "$2" "$1" || { echo "!! VERIFY FAILED: $1: missing $2"; fail=1; }; }
absent() { grep -q "$2" "$1" && { echo "!! VERIFY FAILED: $1: still has $2"; fail=1; } || true; }
check  "$M" "gweather4', required: false"
check  "$M" "libcanberra-gtk3', required: false"
check  "$M" "libgeoclue-2.0', version: '>= 2.3.1', required: false"
check  "$M" "upower-glib', version: '>= 0.99.12', required: false"
check  "$M" "gnome-desktop-4"
absent "$M" "gnome-desktop-3.0"
absent "$M" "geocode-glib-1.0"
check  "$P" "disabled_plugins += \['power', 'color', 'datetime'"
absent "$CM" "join_paths()"
[ "$fail" = 0 ] && echo "gnome-settings-daemon-ios-fixes: all patches applied + verified" || exit 1
