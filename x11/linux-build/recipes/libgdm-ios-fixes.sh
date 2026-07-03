#!/usr/bin/env bash
# gdm iOS source-port fixes (idempotent). We build ONLY the client library, libgdm, because
# gnome-shell statically imports gi://Gdm at boot in 5 files (js/misc/dependencies.js,
# js/misc/systemActions.js, js/ui/unlockDialog.js, js/gdm/loginDialog.js, js/gdm/util.js),
# so the shell will not boot without the Gdm-1.0 typelib + libgdm dylib. iOS realities:
#
#  1. The gdm daemon is Linux-only (PAM, udev, utmp, VT switching, X server management) and
#     its top-level meson.build hard-probes udev/gudev/pam/gtk3/canberra/xcb/logind at
#     configure time. None of that is needed by libgdm, so we REPLACE the top level with a
#     minimal client-only meson.build that configures just common/ + libgdm/.
#  2. libgdm + common use the systemd sd-login C API (no #ifdef). Like libaccountsservice,
#     a single-session sd-login shim (recipes/gdm-sd-login-shim.c) is compiled straight into
#     libgdmcommon; <systemd/sd-login.h> and <sd-daemon.h> resolve to staged stub headers.
#  3. Apple ld has no --version-script; libgdm's map-file link flag is dropped (all symbols
#     exported, which the on-device gir scan wants anyway).
#  4. The Gdm-1.0 typelib is generated ON-DEVICE (the St/Shell/Mutter pattern), so the
#     gnome.generate_gir() block is removed here and the dev package ships lib + headers.
#
# Usage: libgdm-ios-fixes.sh <gdm-src-dir> <recipes-dir>
set -euo pipefail
SRC="${1:?usage: $0 <gdm-src-dir> <recipes-dir>}"
RECIPES="${2:-/work/recipes}"

# --- (1) stage the sd-login/sd-daemon shim headers + implementation -------------
mkdir -p "$SRC/systemd"
cp "$RECIPES/gdm-sd-login.h"      "$SRC/systemd/sd-login.h"
cp "$RECIPES/gdm-sd-daemon.h"     "$SRC/systemd/sd-daemon.h"
cp "$RECIPES/gdm-sd-login-shim.c" "$SRC/common/xios-sd-login-shim.c"

# --- (2) replace the top-level meson.build with the client-only version ---------
# The stock top level is almost entirely daemon configuration (see header). config.h keeps
# only the entries common/ + libgdm/ sources reference; meson_options.txt stays in-tree so
# get_option('log-dir'/'default-path') still resolve.
cat > "$SRC/meson.build" <<'EOF'
project('gdm', 'c',
  version: '46.0',
  license: 'GPL2+',
  meson_version: '>= 0.57',
)

# iOS CLIENT-ONLY build (see recipes/libgdm-ios-fixes.sh): only common/ + libgdm/ are
# configured; the gdm daemon and its Linux-only dependency probes are dropped.

gnome = import('gnome')
pkgconfig = import('pkgconfig')
cc = meson.get_compiler('c')

add_project_arguments('-D_GNU_SOURCE', language: 'c')

gdm_prefix = get_option('prefix')

glib_min_version = '2.68.0'
glib_dep = dependency('glib-2.0', version: '>=' + glib_min_version)
gobject_dep = dependency('gobject-2.0', version: '>=' + glib_min_version)
gio_dep = dependency('gio-2.0', version: '>=' + glib_min_version)
gio_unix_dep = dependency('gio-unix-2.0', version: '>=' + glib_min_version)
libselinux_dep = dependency('libselinux', required: false)

# No logind on iOS: <systemd/sd-login.h> / <sd-daemon.h> resolve to the staged shim headers
# in ./systemd/ (via config_h_dir), and the implementation is compiled into libgdmcommon.
logind_dep = declare_dependency()

config_h_dir = include_directories('.')

conf = configuration_data()
conf.set_quoted('G_LOG_DOMAIN', 'Gdm')
conf.set_quoted('VERSION', meson.project_version())
conf.set_quoted('PACKAGE_VERSION', meson.project_version())
conf.set_quoted('GETTEXT_PACKAGE', meson.project_name())
conf.set_quoted('GNOMELOCALEDIR', gdm_prefix / get_option('localedir'))
conf.set_quoted('DATADIR', gdm_prefix / get_option('datadir'))
conf.set_quoted('SYSCONFDIR', gdm_prefix / get_option('sysconfdir'))
conf.set_quoted('BINDIR', gdm_prefix / get_option('bindir'))
conf.set_quoted('LIBDIR', gdm_prefix / get_option('libdir'))
conf.set_quoted('LIBEXECDIR', gdm_prefix / get_option('libexecdir'))
conf.set_quoted('LOGDIR', get_option('log-dir'))
conf.set_quoted('DMCONFDIR', gdm_prefix / get_option('sysconfdir') / 'dm')
conf.set_quoted('GDMCONFDIR', gdm_prefix / get_option('sysconfdir') / 'gdm')
conf.set_quoted('GDM_DATADIR', gdm_prefix / get_option('datadir') / 'gdm')
conf.set_quoted('GDM_RUN_DIR', gdm_prefix / get_option('localstatedir') / 'run' / 'gdm')
conf.set_quoted('GDM_DEFAULTS_CONF', gdm_prefix / get_option('datadir') / 'gdm' / 'defaults.conf')
conf.set_quoted('GDM_CUSTOM_CONF', gdm_prefix / get_option('sysconfdir') / 'gdm' / 'custom.conf')
conf.set_quoted('GDM_RUNTIME_CONF', gdm_prefix / get_option('localstatedir') / 'run' / 'gdm' / 'custom.conf')
conf.set_quoted('GDM_SESSION_DEFAULT_PATH', get_option('default-path'))
conf.set('ENABLE_PROFILING', false)
conf.set('ENABLE_USER_DISPLAY_SERVER', true)
conf.set('ENABLE_SYSTEMD_JOURNAL', false)
conf.set('ENABLE_WAYLAND_SUPPORT', true)
conf.set('HAVE_SYS_SOCKET_H', true)
conf.set('HAVE_SYS_SOCKIO_H', true)
conf.set('HAVE_STROPTS_H', false)
configure_file(output: 'config.h', configuration: conf)

subdir('common')
subdir('libgdm')
EOF

# --- (3) wire the shim into libgdmcommon + drop daemon-side leftovers ------------
python3 - "$SRC/common/meson.build" <<'PY'
import sys
f = sys.argv[1]
s = open(f).read()
if 'xios-sd-login-shim.c' not in s:
    s = s.replace("  'gdm-settings.c',\n)",
                  "  'gdm-settings.c',\n  'xios-sd-login-shim.c',\n)")
# gdb-cmd is a daemon debugging aid; test-log is a host-run test binary. Neither belongs
# in the cross client build.
s = s.replace("install_data('gdb-cmd')\n", "")
if 'test_log = executable(' in s:
    start = s.index('# test-log exectuable') if '# test-log exectuable' in s else s.index('test_log = executable(')
    end = s.index(')', s.index('test_log = executable(')) + 1
    s = s[:start] + s[end:]
open(f, 'w').write(s)
print('patched common/meson.build')
PY

# --- (4) libgdm/meson.build: no version script on Apple ld, no cross gir ---------
python3 - "$SRC/libgdm/meson.build" <<'PY'
import sys
f = sys.argv[1]
s = open(f).read()
if 'libgdm.map' in s:
    start = s.index('libgdm_link_flags = [')
    end = s.index(']', start) + 1
    s = s[:start] + ('libgdm_link_flags = []'
                     '  # iOS: Apple ld has no version scripts; export everything '
                     '(the on-device gir scan needs the symbols anyway)') + s[end:]
# iOS: DON'T delete the gir block — GATE it on `not meson.is_cross_build()`. The cross build
# skips it (Mach-O g-ir-scanner dumper can't run under qemu), but the on-device NATIVE build
# runs it and produces a COMPLETE Gdm-1.0 typelib (incl. gdm_get_session_ids from gdm-sessions.c,
# which the header-only fallback scan dropped -> gnome-shell systemActions.js crashed). Idempotent.
if 'libgdm_gir = gnome.generate_gir(' in s and 'meson.is_cross_build()' not in s:
    start = s.index('libgdm_gir = gnome.generate_gir(')
    end = s.index('\n)\n', start) + len('\n)\n')
    block = s[start:end]
    s = s[:start] + 'if not meson.is_cross_build()\n' + block + 'endif\n' + s[end:]
open(f, 'w').write(s)
print('patched libgdm/meson.build')
PY

# --- verification -----------------------------------------------------------------
fail=0
check()  { grep -q "$2" "$1" || { echo "!! VERIFY FAILED: $1: missing $2"; fail=1; }; }
absent() { grep -q "$2" "$1" && { echo "!! VERIFY FAILED: $1: still has $2"; fail=1; } || true; }
check  "$SRC/systemd/sd-login.h" "sd_seat_get_sessions"
check  "$SRC/systemd/sd-daemon.h" "sd_booted"
check  "$SRC/common/xios-sd-login-shim.c" "XIOS_SEAT_ID"
check  "$SRC/common/meson.build" "xios-sd-login-shim.c"
absent "$SRC/common/meson.build" "test_log"
check  "$SRC/meson.build" "logind_dep = declare_dependency()"
absent "$SRC/meson.build" "dependency('udev')"
absent "$SRC/libgdm/meson.build" "version-script,"
check  "$SRC/libgdm/meson.build" "generate_gir"
check  "$SRC/libgdm/meson.build" "if not meson.is_cross_build()"
[ "$fail" = 0 ] && echo "libgdm-ios-fixes: all patches applied + verified" || exit 1
