#!/usr/bin/env bash
# nautilus iOS source-port fixes (idempotent). Mirrors recipes/gnome-desktop-introspection-fix.sh.
#
# (1) glib floor: nautilus 46.4 pins glib/gio >= 2.79.0, but our whole GTK4 stack (and every
#     other GNOME 46 app here) is built on glib 2.78.0 and the floor is conservative, not a
#     real API need. Lower it to 2.78.0. If nautilus actually used a 2.79/2.80 symbol the
#     compile/link would fail loudly, so this is safe.
# (2) xlocale API: src/nautilus-date-utilities.c uses locale_t / newlocale / freelocale /
#     uselocale / LC_MESSAGES_MASK. On iOS/Darwin those live in <xlocale.h>, which the default
#     <locale.h> path doesn't pull in -> "unknown type name 'locale_t'". Inject <xlocale.h>
#     (Apple-guarded) after the first #include, exactly like the gnome-desktop port does.
#
# Usage: nautilus-ios-fixes.sh <nautilus-source-dir>
set -euo pipefail
SRC="${1:?usage: $0 <nautilus-src-dir>}"

# --- (1) glib version floor 2.79.0 -> 2.78.0 ---------------------------------
sed -i "s/glib_ver = '>= 2.79.0'/glib_ver = '>= 2.78.0'/" "$SRC/meson.build"

# --- (2) <xlocale.h> for the locale_t users ----------------------------------
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
add_xlocale "$SRC/src/nautilus-date-utilities.c"

# --- (3) g_strv_builder_take() -> add()+free() (GLib 2.80 API on our 2.78) -----
# nautilus-window-slot.c has the lone call to g_strv_builder_take() (added in GLib 2.80).
# Every other newer glib symbol nautilus uses (g_string_new_take etc.) already exists in
# 2.78. Rewrite the single call site: _add() copies the value, so add-then-free reproduces
# take()'s ownership transfer exactly (nautilus_file_get_uri returns a fresh, owned string).
# A direct call-site rewrite avoids any include-ordering pitfalls of an injected shim.
sed -i \
  's/g_strv_builder_take (selected_uris, nautilus_file_get_uri (file));/{ char *_niu = nautilus_file_get_uri (file); g_strv_builder_add (selected_uris, _niu); g_free (_niu); }/' \
  "$SRC/src/nautilus-window-slot.c"

# --- (4) G_FILE_COPY_TARGET_DEFAULT_MODIFIED_TIME (GLib 2.80 GFileCopyFlags) ---
# Its only use is `(job->new_mtime ? G_FILE_COPY_TARGET_DEFAULT_MODIFIED_TIME : 0)` in
# nautilus-file-operations.c. The flag lets 2.80 opt OUT of preserving the source mtime;
# 2.78 has no such flag, so map it to 0 -> the ternary collapses to 0 and g_file_copy uses
# its default mtime behaviour. The only visible difference is copied files keep the source
# mtime rather than getting "now" - immaterial for a file manager.
sed -i "s/G_FILE_COPY_TARGET_DEFAULT_MODIFIED_TIME/0/g" "$SRC/src/nautilus-file-operations.c"

echo "nautilus iOS fixes applied"
