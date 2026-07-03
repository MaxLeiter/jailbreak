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
python3 - "$SRC/src/main.c" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
s = s.replace(
"""#include <link.h>

#ifdef HAVE_EXE_INTROSPECTION
#include <dlfcn.h>
#include <elf.h>
#endif""",
"""#ifdef HAVE_EXE_INTROSPECTION
#include <dlfcn.h>
#include <link.h>
#include <elf.h>
#endif""")
p.write_text(s)
PY

# --- (4b) ATK bridge off for iOS ------------------------------------------------
# at-spi2-core 2.52's atk-bridge links against ATK 2.52 document symbols, while
# the current stack ships standalone ATK 2.38. Accessibility remains initialized
# through Cally, but the AT-SPI bridge adaptor is disabled for this bring-up.
sed -i "s/^atk_bridge_dep = dependency('atk-bridge-2.0')$/atk_bridge_dep = declare_dependency()/" \
  "$SRC/meson.build"
sed -i 's|^#include <atk-bridge.h>$|/* iOS: atk-bridge disabled; current bridge requires newer ATK document symbols. */|' \
  "$SRC/src/main.c"
sed -i 's|^      atk_bridge_adaptor_init (NULL, NULL);$|      /* iOS: atk-bridge disabled until ATK/at-spi versions are aligned. */|' \
  "$SRC/src/main.c"

# --- (5) <xlocale.h> for shell-util.c's locale_t users -------------------------
# shell-util.c uses locale_t / newlocale / uselocale / freelocale / LC_MESSAGES_MASK
# (translate_time_string). On glibc these come in transitively; on iOS/Darwin they
# live in <xlocale.h>, which nothing here pulls in -> "unknown type name 'locale_t'".
# Inject the Apple-guarded include after config.h, exactly like nautilus-ios-fixes.sh.
if ! grep -q "xlocale.h" "$SRC/src/shell-util.c"; then
  python3 - "$SRC/src/shell-util.c" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
s = s.replace(
"""#include "config.h"
""",
"""#include "config.h"

#ifdef __APPLE__
#include <xlocale.h>
#endif
""",
1)
p.write_text(s)
PY
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
  python3 - "$SRC/js/ui/padOsd.js" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
s = s.replace(
"""import Rsvg from 'gi://Rsvg';""",
"""// iOS: librsvg (Rust cross-build) is not shipped; the pad OSD (wacom-tablet only) is the
// sole gi://Rsvg user and never runs on iOS. Stub the namespace so the module loads.
const Rsvg = {Handle: {new_from_file() {throw new Error('padOsd unsupported on iOS (no librsvg)');},
                       new_from_stream_sync() {throw new Error('padOsd unsupported on iOS (no librsvg)');}}};""")
p.write_text(s)
PY
fi

# --- (7) GDM promisify guard: gdm/util.js top-level Gio._promisify()s Gdm.Client /
# Gdm.UserVerifierProxy async methods at MODULE LOAD (pulled in via ui/init.js). On iOS there
# is no GDM daemon, AND the on-device Gdm-1.0 typelib is missing the async _finish mates
# (open_reauthentication_channel_finish, get_user_verifier_finish — the scan dropped them even
# though libgdm.dylib exports them), so _promisify throws -> init.js fails -> the shell never
# paints. Wrap each call so it only promisifies when the _finish method actually exists; the
# GDM auth paths (lock/unlock reauthentication) are unused on iOS anyway. (Blocker #3, docs/
# handoff/gnome-session.md.)
python3 - "$SRC/js/gdm/util.js" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
old = """Gio._promisify(Gdm.Client.prototype, 'open_reauthentication_channel');
Gio._promisify(Gdm.Client.prototype, 'get_user_verifier');
Gio._promisify(Gdm.UserVerifierProxy.prototype,
    'call_begin_verification_for_user');
Gio._promisify(Gdm.UserVerifierProxy.prototype, 'call_begin_verification');"""
new = """// iOS: no GDM daemon + the on-device Gdm-1.0 typelib lacks the async _finish mates,
// so a bare Gio._promisify throws at load. Guard each so gdm/util.js still loads.
const _iosPromisify = (proto, name) => {
    if (proto && typeof proto[`${name}_finish`] === 'function')
        Gio._promisify(proto, name);
};
_iosPromisify(Gdm.Client.prototype, 'open_reauthentication_channel');
_iosPromisify(Gdm.Client.prototype, 'get_user_verifier');
_iosPromisify(Gdm.UserVerifierProxy.prototype, 'call_begin_verification_for_user');
_iosPromisify(Gdm.UserVerifierProxy.prototype, 'call_begin_verification');"""
if old in s:
    s = s.replace(old, new)
    p.write_text(s)
    print("gdm/util.js promisify guarded")
elif "_iosPromisify" in s:
    print("gdm/util.js already guarded")
else:
    sys.exit("!! gdm/util.js promisify block not found (upstream changed?)")
PY

# --- (8) Volume-ectomy: js/ui/status/volume.js's getMixerControl() does a SYNCHRONOUS
# `new Gvc.MixerControl()`, and on iOS that constructor BLOCKS (libgvc/libpulse-17 pa_glib_mainloop
# setup hangs — verified: the constructor never returns). The Output/InputIndicators call it during
# panel construction on the compositor MAIN THREAD, so the whole compositor stops servicing the
# display and an unresponsive-compositor watchdog SIGKILLs gnome-shell ~3.5s into boot (clean
# SIGKILL, no crash report — this was THE first-paint kill; see docs/handoff/gnome-session.md).
# Make the two indicators skip the mixer: `super._init()` runs (so quickSettingsItems=[] is valid),
# then return before getMixerControl(). Volume slider is gone until libgvc/PulseAudio is fixed.
python3 - "$SRC/js/ui/status/volume.js" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
s = p.read_text()
needle = "        this._control = getMixerControl();"
if "iOS: volume/Gvc disabled" in s:
    print("volume.js already ectomied")
elif s.count(needle) >= 2:
    s = s.replace(needle,
                  "        return; // iOS: volume/Gvc disabled (Gvc.MixerControl ctor blocks the compositor)\n" + needle)
    p.write_text(s)
    print("volume.js Output/InputIndicator mixer skipped")
else:
    sys.exit(f"!! volume.js: expected 2x getMixerControl() calls, found {s.count(needle)} (upstream changed?)")
PY

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
check meson.build "atk_bridge_dep = declare_dependency()"
absent src/main.c "atk-bridge.h"
absent src/main.c "atk_bridge_adaptor_init"
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
check js/gdm/util.js "_iosPromisify"
absent js/gdm/util.js "Gio._promisify(Gdm.Client.prototype, 'open_reauthentication_channel');"
check js/ui/status/volume.js "iOS: volume/Gvc disabled"
for f in meson.build src/meson.build src/st/meson.build subprojects/shew/src/meson.build; do
  check "$f" "if not meson.is_cross_build()"
done
[ "$fail" = 0 ] && echo "gnome-shell-ios-fixes: all patches applied" || exit 1
