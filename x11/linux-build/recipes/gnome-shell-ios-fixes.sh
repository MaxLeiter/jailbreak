#!/usr/bin/env bash
# gnome-shell 46 iOS source-port fixes (idempotent). Mirrors recipes/nautilus-ios-fixes.sh.
#
# (1) EDS-ectomy (SKIPPED when WITH_EDS=1): the calendar-server needs evolution-data-server
#     (libecal/libedataserver), which needs ICU. Historically ICU couldn't cross-build here,
#     so EDS was patched OUT per the distribution-chooser decision. Drop the two unconditional
#     EDS dependency() lines and the src/calendar-server subdir (which also drops the
#     org.gnome.Shell.CalendarServer D-Bus .service install). The JS side needs NO patch:
#     js/ui/calendar.js DBusEventSource wraps init_async in try/catch and just waits for a
#     NameOwnerChanged that never comes — empty calendar, no crash.
#     ICU + EDS are NOW BUILT (recipes/icu4c.mk, recipes/evolution-data-server.mk), so the
#     ectomy is reversible: WITH_EDS=1 keeps the stock meson EDS deps + calendar-server and
#     flips the verification below. NOTE the flip needs a PRISTINE source tree — the ectomy
#     sed-DELETES lines from the extracted source and EXTRACT_TAR no-ops on an existing tree,
#     so build-shell.sh's WITH_EDS=1 path wipes build_work/gnome-shell first.
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
# Usage: [WITH_EDS=1] gnome-shell-ios-fixes.sh <gnome-shell-source-dir> [<device-gjs-path>]
set -euo pipefail
SRC="${1:?usage: $0 <gnome-shell-src-dir> [device-gjs-path]}"
GJS="${2:-/var/jb/usr/bin/gjs}"
WITH_EDS="${WITH_EDS:-0}"

# --- (1) EDS-ectomy (skipped when WITH_EDS=1) -----------------------------------
if [ "$WITH_EDS" != 1 ]; then
  sed -i "/^ecal_dep = dependency('libecal-2.0', version: ecal_req)$/d" "$SRC/meson.build"
  sed -i "/^eds_dep = dependency('libedataserver-1.2', version: eds_req)$/d" "$SRC/meson.build"
  sed -i "/^subdir('calendar-server')$/d" "$SRC/src/meson.build"
fi

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

# --- (6) Rsvg-ectomy: gi://Rsvg is reached ONLY via the wacom pad-OSD (show-pad-osd signal
# -> PadOsd -> PadDiagram, padOsd.js), which never fires on iOS; librsvg is a Rust cross-build
# we skip entirely. Two static boot-path sites load the Rsvg typelib: js/misc/dependencies.js
# version-pins it (runs at boot via environment.js), and js/ui/padOsd.js top-level imports it
# (padOsd.js is pulled in by main.js AND windowManager.js). Drop the version-pin, and swap
# padOsd.js's import for a throwing stub const so the module still loads everywhere — the two
# Rsvg.Handle.* uses live in PadDiagram methods that never run without a drawing tablet.
sed -i "/^import 'gi:\/\/Rsvg?version=2.0';$/d" "$SRC/js/misc/dependencies.js"
if grep -q "^import Rsvg from 'gi://Rsvg';" "$SRC/js/ui/padOsd.js"; then
  perl -0pi -e "s{^import Rsvg from 'gi://Rsvg';\$}{// iOS: librsvg (Rust cross-build) is not shipped; the pad OSD (wacom-tablet only) is the\n// sole gi://Rsvg user and never runs on iOS. Stub the namespace so the module loads.\nconst Rsvg = {Handle: {new_from_file() {throw new Error('padOsd unsupported on iOS (no librsvg)');},\n                       new_from_stream_sync() {throw new Error('padOsd unsupported on iOS (no librsvg)');}}};}m" "$SRC/js/ui/padOsd.js"
fi

# --- verification --------------------------------------------------------------
fail=0
check() { grep -q "$2" "$SRC/$1" || { echo "!! VERIFY FAILED: $1: missing $2"; fail=1; }; }
absent() { grep -q "$2" "$SRC/$1" && { echo "!! VERIFY FAILED: $1: still has $2"; fail=1; } || true; }
if [ "$WITH_EDS" = 1 ]; then
  check meson.build "libecal-2.0"
  check meson.build "libedataserver-1.2"
  check src/meson.build "subdir('calendar-server')"
else
  absent meson.build "libecal-2.0"
  absent meson.build "libedataserver-1.2"
  absent src/meson.build "subdir('calendar-server')"
fi
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
absent js/misc/dependencies.js "gi://Rsvg"
absent js/ui/padOsd.js "from 'gi://Rsvg'"
check js/ui/padOsd.js "padOsd unsupported on iOS"
for f in meson.build src/meson.build src/st/meson.build subprojects/shew/src/meson.build; do
  check "$f" "if not meson.is_cross_build()"
done
[ "$fail" = 0 ] && echo "gnome-shell-ios-fixes: all patches applied" || exit 1
