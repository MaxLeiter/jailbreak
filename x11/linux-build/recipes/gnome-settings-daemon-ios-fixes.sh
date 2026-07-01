#!/usr/bin/env bash
# gnome-settings-daemon 46 iOS source-port fixes (idempotent) — a MINIMAL gsd for the Xios
# GNOME session. See docs/gnome-session-plan.md for the plugin audit. Rationale:
#
# The gsd CORE daemon (gnome-settings-daemon/) links only gio; all the heavy top-level
# dependencies are consumed ONLY by plugins. We keep the plugins that make sense on a
# Wayland iOS tablet and need no absent hardware/service:
#   KEEP: a11y-settings, housekeeping, keyboard, screensaver-proxy, POWER (see below)
#   DROP: color (colord/geoclue), datetime (geoclue/gweather/timedated),
#         media-keys (gvc/upower/canberra), sound (canberra/alsa),
#         xsettings (X11-only, no display in a Wayland session), sharing (NetworkManager),
#         print-notifications (CUPS), rfkill, wwan (ModemManager), smartcard (pcsc/gck),
#         wacom (libwacom), usb-protection (USBGuard).
# The dropped plugins are the only consumers of geocode-glib, gweather4, libcanberra-gtk3 and
# libgeoclue, so those deps become required:false (never resolved). libnotify stays
# (housekeeping needs it) and is built by recipes/libnotify.mk. gnome-desktop is retargeted
# 3.0 -> 4 (we ship only the GTK4/base library; libcommon + the kept plugins use only
# GTK-independent gnome-desktop API).
#
# POWER PLUGIN (section 5): un-dropped for battery handling + the brightness slider. upower-glib
# is now provided at runtime by xios-hwbridged (org.freedesktop.UPower, IOKit-backed), and the
# heavy libcanberra-gtk3 + X11/xext deps are excised: canberra event sounds resolve to a no-op
# stub header, and the one raw-X11 site (gpm-common.c's Xorg-DPMS defeat) is neutralized. The
# Darwin backlight backend in gsd-backlight.c (reads/writes the xios_backlight node) is added
# separately.
#
# Usage: gnome-settings-daemon-ios-fixes.sh <gsd-source-dir> [<recipes-dir>]
set -euo pipefail
SRC="${1:?usage: $0 <gsd-src-dir> [<recipes-dir>]}"
RECIPES="${2:-/work/recipes}"
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
# Append to disabled_plugins right after it is initialised (idempotent by marker). POWER is
# KEPT (section 5 makes it iOS-buildable); the rest need absent hardware/services or X11.
if ! grep -q "# iOS: minimal plugin set" "$P"; then
  perl -0pi -e "s/^disabled_plugins = \[\]\n/disabled_plugins = []\n# iOS: minimal plugin set — drop everything that needs absent hardware\/services or X11.\ndisabled_plugins += ['color', 'datetime', 'media-keys', 'sound', 'xsettings', 'sharing']\n/m" "$P"
fi
# If a prior run of this script disabled 'power', re-enable it (idempotent un-drop).
sed -i "s/disabled_plugins += \['power', /disabled_plugins += ['/" "$P"

# --- (4) neutralize gsd's broken macOS bundle_loader hack ----------------------
# plugins/common/meson.build has an `if host_is_darwin` block that appends a malformed
# ldflag: join_paths() is called with NO arguments (meson errors "join_paths takes at
# least 1 arguments"). It is a half-finished macOS bundle hack and is meaningless here -
# libcommon is a normal static archive linked into the plugin executables. Blank the line.
CM="$SRC/plugins/common/meson.build"
if grep -q "bundle_loader" "$CM"; then
  sed -i '/bundle_loader/c\  # iOS: dropped gsd malformed macOS bundle_loader ldflag (join_paths no-arg).' "$CM"
fi

# --- (5) make the POWER plugin iOS-buildable -----------------------------------
# Un-dropped in section 3. Two Linux-only deps must go and one raw-X11 file must be gated.
PM="$SRC/plugins/power/meson.build"
GPM="$SRC/plugins/power/gpm-common.c"

# 5a. canberra event sounds -> no-op stub header on the plugin's include path; drop the
#     libcanberra-gtk3 + X11 + Xext deps from the power executable (all Linux/X11-only).
mkdir -p "$SRC/plugins/power/ios-stubs"
cp "$RECIPES/gsd-power-canberra-gtk.h" "$SRC/plugins/power/ios-stubs/canberra-gtk.h"
sed -i '/^  libcanberra_gtk_dep,$/d'    "$PM"
sed -i '/^  x11_dep,$/d'                "$PM"
sed -i "/^  dependency('xext')\$/d"     "$PM"
if ! grep -q "ios-stubs" "$PM"; then
  # add the stub dir to the plugin's cflags (search path for <canberra-gtk.h>)
  perl -0pi -e "s/(cflags \+= \['-DLIBEXECDIR=\"\@0\@\"'\.format\(gsd_libexecdir\)\])/\$1\ncflags += ['-I' + meson.current_source_dir() \/ 'ios-stubs']  # iOS: canberra-gtk.h stub/m" "$PM"
fi

# 5b. gpm-common.c: gate the X11 screensaver/DPMS machinery behind !__APPLE__ (mirrors
#     gsd-backlight.c's __linux__ gating). There is no X server in a Wayland iOS session, so
#     disable_builtin_screensaver() becomes a no-op and the DPMS-defeat is skipped.
if ! grep -q "iOS: no X server" "$GPM"; then
  python3 - "$GPM" <<'PY'
import sys
f = sys.argv[1]
s = open(f).read()

# (i) guard the two X11 includes
s = s.replace(
  "#include <gdk/gdkx.h>\n#include <X11/extensions/dpms.h>\n",
  "#ifndef __APPLE__\n#include <gdk/gdkx.h>\n#include <X11/extensions/dpms.h>\n#endif\n")

# (ii) disable_builtin_screensaver: no-op on iOS (returns FALSE, does no X calls)
s = s.replace(
  "disable_builtin_screensaver (gpointer unused)\n{\n",
  "disable_builtin_screensaver (gpointer unused)\n{\n"
  "#ifdef __APPLE__\n"
  "        (void) unused;\n"
  "        return FALSE;  /* iOS: no X server built-in screensaver to police */\n"
  "#else\n")
s = s.replace(
  "                XSync (GDK_DISPLAY_XDISPLAY (gdk_display_get_default ()), FALSE);\n"
  "        }\n\n        return TRUE;\n}\n",
  "                XSync (GDK_DISPLAY_XDISPLAY (gdk_display_get_default ()), FALSE);\n"
  "        }\n\n        return TRUE;\n#endif  /* !__APPLE__ */\n}\n")

# (iii) gsd_power_enable_screensaver_watchdog: skip the raw-X11 DPMS-defeat on iOS
s = s.replace(
  "        int dummy;\n        guint id;\n\n"
  "        /* Make sure that Xorg's DPMS extension never gets in our\n"
  "         * way. The defaults are now applied in Fedora 20 from\n"
  "         * being \"0\" by default to being \"600\" by default */\n"
  "        gdk_x11_display_error_trap_push (gdk_display_get_default ());\n"
  "        if (DPMSQueryExtension(GDK_DISPLAY_XDISPLAY (gdk_display_get_default ()), &dummy, &dummy))\n"
  "                DPMSSetTimeouts (GDK_DISPLAY_XDISPLAY (gdk_display_get_default ()), 0, 0, 0);\n"
  "        gdk_x11_display_error_trap_pop_ignored (gdk_display_get_default ());\n",
  "        guint id;\n\n"
  "#ifndef __APPLE__\n"
  "        int dummy;\n\n"
  "        /* Make sure that Xorg's DPMS extension never gets in our way. */\n"
  "        gdk_x11_display_error_trap_push (gdk_display_get_default ());\n"
  "        if (DPMSQueryExtension(GDK_DISPLAY_XDISPLAY (gdk_display_get_default ()), &dummy, &dummy))\n"
  "                DPMSSetTimeouts (GDK_DISPLAY_XDISPLAY (gdk_display_get_default ()), 0, 0, 0);\n"
  "        gdk_x11_display_error_trap_pop_ignored (gdk_display_get_default ());\n"
  "#endif\n")

open(f, "w").write(s)
print("gated gpm-common.c X11 screensaver/DPMS behind !__APPLE__")
PY
fi

# --- verification --------------------------------------------------------------
fail=0
check()  { grep -q "$2" "$1" || { echo "!! VERIFY FAILED: $1: missing $2"; fail=1; }; }
checkF() { grep -qF "$2" "$1" || { echo "!! VERIFY FAILED: $1: missing $2"; fail=1; }; }
absent() { grep -q "$2" "$1" && { echo "!! VERIFY FAILED: $1: still has $2"; fail=1; } || true; }
check  "$M" "gweather4', required: false"
check  "$M" "libcanberra-gtk3', required: false"
check  "$M" "libgeoclue-2.0', version: '>= 2.3.1', required: false"
check  "$M" "upower-glib', version: '>= 0.99.12', required: false"
check  "$M" "gnome-desktop-4"
absent "$M" "gnome-desktop-3.0"
absent "$M" "geocode-glib-1.0"
check  "$P" "disabled_plugins += \['color', 'datetime'"
absent "$P" "'power', 'color'"
absent "$CM" "join_paths()"
# section 5: power plugin iOS-buildable
check  "$SRC/plugins/power/ios-stubs/canberra-gtk.h" "ca_context_play"
absent "$PM" "libcanberra_gtk_dep,"
absent "$PM" "x11_dep,"
check  "$PM" "ios-stubs"
check  "$GPM" "iOS: no X server"
checkF "$GPM" "#endif  /* !__APPLE__ */"
[ "$fail" = 0 ] && echo "gnome-settings-daemon-ios-fixes: all patches applied + verified" || exit 1
