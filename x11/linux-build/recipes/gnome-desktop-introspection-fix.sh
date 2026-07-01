#!/usr/bin/env bash
# gnome-desktop introspection=false + iOS source-port fixes (idempotent).
#
# (1) gnome.generate_gir() is called unconditionally in
#     libgnome-desktop/{,gnome-bg/,gnome-rr/}meson.build, but
#     libgnome_desktop_base_gir is only assigned under `if get_option('introspection')`.
#     With -Dintrospection=false the subdirs' generate_gir hits "Unknown variable".
#     Drop the base dep's lone gir sources ref and gate the two subdir generate_gir
#     blocks (`else <var> = []`).
# (2) Several sources use the xlocale API (locale_t / newlocale / freelocale /
#     LC_MESSAGES_MASK). On iOS/Darwin those need <xlocale.h>, which the default
#     <locale.h> path doesn't pull in -> "unknown type name 'locale_t'". Inject
#     <xlocale.h> (Apple-guarded) after the first #include in each such file.
#
# Usage: gnome-desktop-introspection-fix.sh <gnome-desktop-source-dir>
set -euo pipefail
SRC="${1:?usage: $0 <gnome-desktop-src-dir>}"
BASE="$SRC/libgnome-desktop"

# --- (1) introspection=false gir gating --------------------------------------
sed -i "/^[[:space:]]*libgnome_desktop_base_gir,[[:space:]]*$/d" "$BASE/meson.build"

gate_gir() {
  local f="$1"
  [ -f "$f" ] || return 0
  grep -q "X11IOS_GIR_GATED" "$f" && return 0
  awk '
    /^[A-Za-z_][A-Za-z0-9_]* = gnome\.generate_gir\(/ {
      var=$1
      print "if get_option(\047introspection\047) # X11IOS_GIR_GATED"
      print; ingir=1; next
    }
    ingir==1 && /^\)[[:space:]]*$/ {
      print; print "else"; print var " = []"; print "endif"; ingir=0; next
    }
    { print }
  ' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
}
gate_gir "$BASE/gnome-bg/meson.build"
gate_gir "$BASE/gnome-rr/meson.build"

# --- (2) xlocale.h for the locale_t users ------------------------------------
add_xlocale() {
  local f="$1"
  [ -f "$f" ] || return 0
  python3 - "$f" <<'PY'
import sys
f = sys.argv[1]
s = open(f).read()
if "xlocale.h" in s:
    sys.exit(0)
lines = s.splitlines(keepends=True)
out, done = [], False
for ln in lines:
    out.append(ln)
    if not done and ln.lstrip().startswith("#include"):
        out.append("#ifdef __APPLE__\n#include <xlocale.h>\n#endif\n")
        done = True
if done:
    open(f, "w").write("".join(out))
    print("xlocale.h added to %s" % f.split('/')[-1])
else:
    sys.exit("ERROR: no #include anchor in %s" % f)
PY
}
add_xlocale "$BASE/gnome-gettext-portable.h"
add_xlocale "$BASE/gnome-gettext-portable.c"
add_xlocale "$BASE/gnome-wall-clock.c"
add_xlocale "$BASE/gnome-languages.c"
add_xlocale "$BASE/gnome-xkb-info.c"

echo "gnome-desktop iOS fixes applied"
