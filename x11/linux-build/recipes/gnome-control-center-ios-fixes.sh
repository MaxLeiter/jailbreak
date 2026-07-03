#!/usr/bin/env bash
# gnome-control-center 46 iOS source-port fixes (idempotent). Mirrors gnome-shell-ios-fixes.sh.
#
# gnome-control-center (GNOME Settings) is a per-panel GTK4/libadwaita app. On a non-Linux host
# it ALREADY drops the network/bluetooth/wacom panels (they are appended only under
# `host_is_linux` / `host_is_linux_not_s390` in panels/meson.build) — but it is NOT configure-
# clean off Linux and several REQUIRED top-level deps have no iOS backend. This script makes a
# tractable config-panel build configure and compile.
#
# WHAT THIS PATCHES (verified against gnome-control-center-46.4 source):
#  (1) wwan landmine — panels/meson.build lists 'wwan' in the UNCONDITIONAL array, but
#      panels/wwan/meson.build references `network_manager_deps` which meson.build only defines
#      inside `if host_is_linux` (no else). Off Linux -> "unknown variable network_manager_deps"
#      at configure. Fix: drop 'wwan' from the array (it belongs with network under host_is_linux).
#  (2) goa ectomy — `goa_dep = dependency('goa-1.0', ...)` is REQUIRED but gnome-online-accounts
#      is not built for iOS (it pulls librest + webkitgtk for provider auth). Its ONLY consumer is
#      the online-accounts panel (grep-verified). Drop the dep line + the panel.
#  (3) cups ectomy — cups is `required: false` but an `assert(cups_dep.found(), ...)` + two CUPS
#      header asserts abort configure when cups is absent. Its only consumer is the printers
#      panel. Drop the asserts + the panel.
#  (4) panel trim — keep only the panels whose backends exist (or degrade gracefully) on iOS.
#
# STILL REQUIRED as COMPANION work (NOT done here — see recipes/gnome-control-center.mk header):
#  - libgudev STUB: `gudev-1.0` is a REQUIRED dep consumed by panels/common (gsd-device-manager.c,
#    linked by the keyboard/mouse panels). iOS has no udev, so the local stub returns empty
#    enumerations while input still arrives through Wayland/Mutter.
#  - libpwquality/libgsound STUBS: provide password scoring/generation and short UI sounds without
#    pulling cracklib/libcanberra onto iOS.
#  - Bluetooth panel (Max's priority): auto-DROPPED here. To ENABLE it, pass WITH_BLUETOOTH=1:
#    that force-adds 'bluetooth' + defines gnome_bluetooth_dep unconditionally. Prereq: build
#    gnome-bluetooth (libgnome-bluetooth-ui-3.0) with its own udev/gsound ectomy. The org.bluez
#    backend is already provided by xios-bluez-stub (wayland/xios-bluez-stub.m) — validated to
#    enumerate real paired devices on device.
#
# Usage: [WITH_BLUETOOTH=1] gnome-control-center-ios-fixes.sh <gcc-source-dir>
set -euo pipefail
SRC="${1:?usage: $0 <gnome-control-center-src-dir>}"
WITH_BLUETOOTH="${WITH_BLUETOOTH:-0}"

PM="$SRC/panels/meson.build"
MB="$SRC/meson.build"

# --- (1) wwan landmine: drop 'wwan' from the unconditional panels array --------------------
python3 - "$PM" <<'PY'
import sys, re
f = sys.argv[1]; s = open(f).read()
new = re.sub(r"^\s*'wwan',\s*\n", "", s, flags=re.M)
if new == s and "'wwan'" in s:
    sys.exit("!! could not remove 'wwan' from panels array (upstream changed?)")
open(f, "w").write(new)
print("panels: dropped 'wwan' (network_manager_deps landmine)")
PY

# --- (2) goa ectomy + (3) cups asserts: patch top meson.build ------------------------------
python3 - "$MB" <<'PY'
import sys, re
f = sys.argv[1]; s = open(f).read()

# (2) drop the goa dependency() line (only the online-accounts panel uses goa_dep).
s2 = re.sub(r"^goa_dep = dependency\('goa-1\.0'.*\n", "", s, flags=re.M)
if s2 == s:
    print("  (goa_dep line already absent)")
s = s2

# (3) neuter the CUPS asserts so a missing/absent cups doesn't abort configure. The printers
# panel is dropped below, so cups is never actually linked.
s = re.sub(r"^assert\(cups_dep\.found\(\).*\n", "", s, flags=re.M)
s = re.sub(r"^\s*assert\(cc\.has_header\(header\[1\].*\n", "    true\n", s, flags=re.M)

# (3b) relax the x11 (>=1.8) / xi version pins. GTK4 on iOS is Wayland-only, so the X11 code
# paths behind GDK_WINDOWING_X11 are compiled out; the pin only blocks configure against the
# stack's libX11 1.7.x. Keep the dep (it still links) but drop the version constraint.
s = re.sub(r"x11_dep = dependency\('x11', version: '>= 1\.8'\)",
           "x11_dep = dependency('x11')", s)
s = re.sub(r"xi_dep = dependency\('xi', version: '>= 1\.2'\)",
           "xi_dep = dependency('xi')", s)

# (3c) neuter the polkit ITS-gettext assert loop. It only gates BUILD-TIME translation of
# .policy files (find_xdg_file.py locating polkit.its/.loc in XDG_DATA_DIRS); irrelevant to
# running the app, and the cross sysroot doesn't ship gettext/its/. Make the probe non-fatal.
s = s.replace("r = run_command('build-aux/meson/find_xdg_file.py', polkit_file, check: true)",
              "r = run_command('build-aux/meson/find_xdg_file.py', polkit_file, check: false)")
s = s.replace("assert(r.returncode() == 0, 'ITS support missing from polkit, please upgrade or contact your distribution')",
              "# iOS: polkit ITS assert neutered (build-time .policy translation only)")

open(f, "w").write(s)
print("meson.build: goa dep dropped, CUPS asserts neutered, x11/xi version pins relaxed")
PY

# --- (4) panel trim ------------------------------------------------------------------------
#   online-accounts -> goa (not built), printers -> cups (not built),
#   color  -> colord-gtk4 (not built; ICC display-profile mgmt, niche on a tablet — restore by
#             building colord-gtk with gtk4 and removing 'color' from this list).
#   system -> udisks2 (>=2.8.2, Linux disk daemon; About disk size) + krb5 (kerberos, Users
#             enterprise login) — both Linux-only, and cc-system-details-window.c / the users
#             code call them unconditionally. Dropped for the first build (loses About / Users /
#             Region / Date&Time / Remote-desktop). RESTORE by providing a udisks2 client stub +
#             krb5 stub (or guarding those two .c sites) and removing 'system' from this list.
for p in online-accounts printers color system; do
  python3 - "$PM" "$p" <<'PY'
import sys, re
f, panel = sys.argv[1], sys.argv[2]
s = open(f).read()
new = re.sub(r"^\s*'%s',\s*\n" % re.escape(panel), "", s, flags=re.M)
if new != s:
    open(f, "w").write(new); print("panels: dropped '%s'" % panel)
else:
    print("panels: '%s' already absent" % panel)
PY
done

# --- (4a) shell panel-loader: drop table entries for the ectomied panels ---------------------
# shell/cc-panel-loader.c has a hardcoded default_panels[] that references each panel's
# cc_*_get_type() unconditionally (color/online-accounts/printers/system have no BUILD_ guard),
# so dropping those panels leaves undefined symbols at the final shell link. Remove the matching
# PANEL_TYPE(...) rows and their `extern GType` decls for every panel we trimmed.
python3 - "$SRC/shell/cc-panel-loader.c" online-accounts printers color system <<'PY'
import sys, re
f = sys.argv[1]; dropped = set(sys.argv[2:])
lines = open(f).read().splitlines(keepends=True)
# First pass: find the get_type symbol for each dropped panel from its PANEL_TYPE row.
syms = set()
row = re.compile(r'PANEL_TYPE\("([^"]+)",\s*([A-Za-z0-9_]+)')
for ln in lines:
    m = row.search(ln)
    if m and m.group(1) in dropped:
        syms.add(m.group(2))
out = []
for ln in lines:
    m = row.search(ln)
    if m and m.group(1) in dropped:
        continue  # drop the table row
    e = re.match(r'\s*extern GType ([A-Za-z0-9_]+) \(void\);', ln)
    if e and e.group(1) in syms:
        continue  # drop the extern decl
    out.append(ln)
open(f, "w").write("".join(out))
print("shell/cc-panel-loader.c: removed %d dropped-panel rows (%s)" % (len(syms), ", ".join(sorted(dropped))))
PY

# --- (4b) privacy panel: ectomy the firmware-security subpage --------------------------------
# The firmware-security page (fwupd Host Security ID / Secure Boot) is Linux-PC-firmware specific
# and pulls <glibtop/fsusage.h>, which the heavily-stubbed iOS libgtop does not provide. It is
# self-contained: 5 cc-firmware-security-*.c sources + the libgtop-2.0 dep + an #include +
# g_type_ensure in cc-privacy-panel.c + 4 .ui entries in the gresource. Drop them all.
PRIV="$SRC/panels/privacy"
python3 - "$PRIV/meson.build" "$PRIV/cc-privacy-panel.c" "$PRIV/privacy.gresource.xml" <<'PY'
import sys, re
mb, panelc, gres = sys.argv[1], sys.argv[2], sys.argv[3]

s = open(mb).read()
for f in ("cc-firmware-security-boot-dialog.c", "cc-firmware-security-dialog.c",
          "cc-firmware-security-help-dialog.c", "cc-firmware-security-page.c",
          "cc-firmware-security-utils.c"):
    s = re.sub(r"^\s*'%s',\s*\n" % re.escape(f), "", s, flags=re.M)
# libgtop-2.0 was only used by firmware-security; drop the dep so it isn't required.
s = re.sub(r"^\s*dependency\('libgtop-2\.0'\),\s*\n", "", s, flags=re.M)
open(mb, "w").write(s)

c = open(panelc).read()
c = c.replace('#include "cc-firmware-security-page.h"\n', "")
c = re.sub(r"^\s*g_type_ensure \(CC_TYPE_FIRMWARE_SECURITY_PAGE\);\s*\n", "", c, flags=re.M)
open(panelc, "w").write(c)

g = open(gres).read()
g = re.sub(r'^\s*<file[^>]*>cc-firmware-security-[^<]*</file>\s*\n', "", g, flags=re.M)
open(gres, "w").write(g)
print("privacy: firmware-security subpage ectomied (+ libgtop dep dropped)")
PY

# --- (5) Bluetooth panel (opt-in): force-enable for iOS -------------------------------------
# gnome-control-center gates 'bluetooth' + gnome_bluetooth_dep behind host_is_linux_not_s390.
# With WITH_BLUETOOTH=1 we lift both so the panel builds against libgnome-bluetooth-ui-3.0 and
# talks to org.bluez (our xios-bluez-stub). Requires gnome-bluetooth to be built.
if [ "$WITH_BLUETOOTH" = 1 ]; then
  python3 - "$MB" "$PM" <<'PY'
import sys, re
mb, pm = sys.argv[1], sys.argv[2]
s = open(mb).read()
# Define gnome_bluetooth_dep unconditionally (idempotent) before the host_is_linux_not_s390 block.
if "gnome_bluetooth_dep = dependency('gnome-bluetooth-ui-3.0')  # iOS-forced" not in s:
    s = s.replace(
        "if host_is_linux_not_s390\n  # gnome-bluetooth\n  gnome_bluetooth_dep = dependency('gnome-bluetooth-ui-3.0')",
        "gnome_bluetooth_dep = dependency('gnome-bluetooth-ui-3.0')  # iOS-forced\nif host_is_linux_not_s390\n  # gnome-bluetooth (dep hoisted above for iOS)")
    # flip the BUILD/HAVE_BLUETOOTH config to always-true
    s = s.replace("config_h.set('BUILD_BLUETOOTH', host_is_linux_not_s390,",
                  "config_h.set('BUILD_BLUETOOTH', true,")
    s = s.replace("config_h.set('HAVE_BLUETOOTH', host_is_linux_not_s390,",
                  "config_h.set('HAVE_BLUETOOTH', true,")
    open(mb, "w").write(s)
    print("meson.build: gnome_bluetooth_dep hoisted + BLUETOOTH forced on")
p = open(pm).read()
if "'bluetooth'," not in p.split("if host_is_linux")[0]:
    p = p.replace("  'universal-access',\n", "  'universal-access',\n  'bluetooth',\n")
    open(pm, "w").write(p)
    print("panels: force-added 'bluetooth'")
PY
fi

# --- verification --------------------------------------------------------------------------
fail=0
grep -q "'wwan'" "$PM" && { echo "!! VERIFY: 'wwan' still in panels array"; fail=1; }
grep -q "goa-1.0" "$MB" && { echo "!! VERIFY: goa-1.0 dependency still present"; fail=1; }
grep -qE "^assert\(cups_dep\.found" "$MB" && { echo "!! VERIFY: cups assert still present"; fail=1; }
grep -q "'online-accounts'" "$PM" && { echo "!! VERIFY: online-accounts panel still listed"; fail=1; }
grep -q "'printers'" "$PM" && { echo "!! VERIFY: printers panel still listed"; fail=1; }
[ "$fail" = 0 ] && echo "gnome-control-center-ios-fixes: all patches applied (WITH_BLUETOOTH=$WITH_BLUETOOTH)" || exit 1
