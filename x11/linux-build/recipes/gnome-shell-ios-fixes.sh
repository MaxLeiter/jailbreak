#!/usr/bin/env bash
# gnome-shell 46 iOS source-port fixes (idempotent). Mirrors recipes/nautilus-ios-fixes.sh.
#
# (1) EDS-ectomy: the calendar-server needs evolution-data-server (libecal/libedataserver),
#     which needs ICU — ICU is being built separately (native-then-cross); until it lands,
#     EDS is patched OUT per the distribution-chooser decision. Drop the two unconditional
#     EDS dependency() lines and the src/calendar-server subdir (which also drops the
#     org.gnome.Shell.CalendarServer D-Bus .service install). The JS side needs NO patch:
#     js/ui/calendar.js DBusEventSource wraps init_async in try/catch and just waits for a
#     NameOwnerChanged that never comes — empty calendar, no crash.
# (2) GIR cross-gating: gnome-shell has no introspection option — the St/Shell/Shew/Gvc
#     girs are generated unconditionally, but cross can't exec the gir dumper (gnome-plan
#     Blocker #2; same reason mutter builds with -Dintrospection=false). Wrap every
#     generate_gir block in `if not meson.is_cross_build()` so ONE patched source serves
#     both builds: off-device cross (girs skipped) and on-device native (girs built, the
#     gir-build-mutter-ondevice.sh pattern).
# (3) host-gjs decoupling: meson.build find_program()s gjs at configure time, but gjs is a
#     TARGET package here, and gjs.full_path() is baked into the dbusServices' D-Bus
#     Exec= lines. Make the probe non-required and bake the device path instead.
#
# Usage: gnome-shell-ios-fixes.sh <gnome-shell-source-dir> [<device-gjs-path>]
set -euo pipefail
SRC="${1:?usage: $0 <gnome-shell-src-dir> [device-gjs-path]}"
GJS="${2:-/var/jb/usr/bin/gjs}"

# --- (1) EDS-ectomy -----------------------------------------------------------
sed -i "/^ecal_dep = dependency('libecal-2.0', version: ecal_req)$/d" "$SRC/meson.build"
sed -i "/^eds_dep = dependency('libedataserver-1.2', version: eds_req)$/d" "$SRC/meson.build"
sed -i "/^subdir('calendar-server')$/d" "$SRC/src/meson.build"

# --- (2) GIR cross-gating -----------------------------------------------------
# gvc subproject: don't force introspection on for the cross build.
sed -i "s/^    'introspection=true',$/    'introspection=' + (meson.is_cross_build() ? 'false' : 'true'),/" \
  "$SRC/meson.build"

# Wrap a block [start-marker .. first end-marker after it] in `if not meson.is_cross_build()`.
wrap_gir() {
  local f="$1" start="$2" end="$3"
  python3 - "$f" "$start" "$end" <<'PY'
import sys
f, start, end = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(f).read()
i = s.find(start)
if i < 0:
    sys.exit(f"!! start marker not found in {f}: {start!r}")
# idempotency: already guarded?
guard = "if not meson.is_cross_build()"
if s[max(0, i - 200):i].count(guard):
    sys.exit(0)
j = s.find(end, i)
if j < 0:
    sys.exit(f"!! end marker not found in {f}: {end!r}")
j += len(end)
s = s[:i] + guard + "\n" + s[i:j] + "\nendif" + s[j:]
open(f, "w").write(s)
print(f"gir block guarded in {f.split('/')[-1]}")
PY
}

wrap_gir "$SRC/meson.build" \
  "libgvc_gir = libgvc.get_variable('libgvc_gir')" \
  "libgvc_gir = libgvc.get_variable('libgvc_gir')"
wrap_gir "$SRC/src/st/meson.build" \
  "libst_gir = gnome.generate_gir(libst," \
  "kwargs: introspection_common,
)"
wrap_gir "$SRC/src/meson.build" \
  "libshell_gir_includes = [" \
  "kwargs: introspection_common,
)"
wrap_gir "$SRC/subprojects/shew/src/meson.build" \
  "libshew_gir = gnome.generate_gir(libshew," \
  "install: true,
)"

# --- (3) host-gjs decoupling ---------------------------------------------------
sed -i "s/^gjs = find_program('gjs')$/gjs = find_program('gjs', required: false)/" "$SRC/meson.build"
sed -i "s|serviceconf.set('gjs', gjs.full_path())|serviceconf.set('gjs', '$GJS')|" \
  "$SRC/js/dbusServices/meson.build"

# --- (4) <link.h> guard: main.c includes <link.h> unconditionally (an ELF/Linux header
# absent on Darwin), while <elf.h> and every ElfW() use are already gated on
# HAVE_EXE_INTROSPECTION (false on iOS: cc.has_header('elf.h') and 'link.h' both fail).
# Move the bare include inside that same guard so the non-ELF build compiles.
perl -0pi -e 's{#include <link\.h>\n\n#ifdef HAVE_EXE_INTROSPECTION\n#include <dlfcn\.h>\n#include <elf\.h>\n#endif}{#ifdef HAVE_EXE_INTROSPECTION\n#include <dlfcn.h>\n#include <link.h>\n#include <elf.h>\n#endif}' "$SRC/src/main.c"

# --- (5) <xlocale.h> for shell-util.c's locale_t users -------------------------
# shell-util.c uses locale_t / newlocale / uselocale / freelocale / LC_MESSAGES_MASK
# (translate_time_string). On glibc these come in transitively; on iOS/Darwin they
# live in <xlocale.h>, which nothing here pulls in -> "unknown type name 'locale_t'".
# Inject the Apple-guarded include after config.h, exactly like nautilus-ios-fixes.sh.
if ! grep -q "xlocale.h" "$SRC/src/shell-util.c"; then
  perl -0pi -e 's{(#include "config.h"\n)}{$1\n#ifdef __APPLE__\n#include <xlocale.h>\n#endif\n}' \
    "$SRC/src/shell-util.c"
fi

# --- verification --------------------------------------------------------------
fail=0
check() { grep -q "$2" "$SRC/$1" || { echo "!! VERIFY FAILED: $1: missing $2"; fail=1; }; }
absent() { grep -q "$2" "$SRC/$1" && { echo "!! VERIFY FAILED: $1: still has $2"; fail=1; } || true; }
absent meson.build "libecal-2.0"
absent meson.build "libedataserver-1.2"
absent src/meson.build "subdir('calendar-server')"
check meson.build "introspection=' + (meson.is_cross_build()"
check meson.build "find_program('gjs', required: false)"
check js/dbusServices/meson.build "serviceconf.set('gjs', '$GJS')"
# link.h must now sit inside the HAVE_EXE_INTROSPECTION guard (right after dlfcn.h), and
# NOT be the bare include right after atk-bridge.h.
if grep -A1 '#include <atk-bridge.h>' "$SRC/src/main.c" | grep -q '#include <link.h>'; then
  echo "!! VERIFY FAILED: src/main.c: <link.h> still unguarded after atk-bridge.h"; fail=1
fi
if ! (grep -A1 '#include <dlfcn.h>' "$SRC/src/main.c" | grep -q '#include <link.h>'); then
  echo "!! VERIFY FAILED: src/main.c: <link.h> not moved inside HAVE_EXE_INTROSPECTION"; fail=1
fi
check src/shell-util.c "xlocale.h"
for f in meson.build src/meson.build src/st/meson.build subprojects/shew/src/meson.build; do
  check "$f" "if not meson.is_cross_build()"
done
[ "$fail" = 0 ] && echo "gnome-shell-ios-fixes: all patches applied" || exit 1
