#!/usr/bin/env bash
# accountsservice iOS source-port fixes (idempotent). We build ONLY the client library,
# libaccountsservice, because gnome-shell statically imports gi://AccountsService in its
# panel boot path (js/misc/systemActions.js) and the shell will not boot without the
# AccountsService typelib + dylib. Two iOS realities:
#
#  1. The accounts-daemon is Linux-only (utmp/wtmp, crypt, shadow) and cannot compile on
#     Darwin. Drop it - the library is a standalone GDBus client and does not need it. The
#     org.freedesktop.Accounts data comes from a stub daemon (or the shell degrades to an
#     empty user name and still boots).
#  2. The library itself uses the systemd sd-login C API (no #ifdef) to enumerate the
#     seat/sessions. There is no logind on iOS, so we compile a single-session sd-login shim
#     (recipes/accountsservice-sd-login-shim.c) straight into the library and drop the
#     libsystemd dependency. The typelib is generated ON-DEVICE (like St/Shell/Mutter), so
#     we build -Dintrospection=false here.
#
# Usage: accountsservice-ios-fixes.sh <accountsservice-src-dir> <recipes-dir>
set -euo pipefail
SRC="${1:?usage: $0 <accountsservice-src-dir> <recipes-dir>}"
RECIPES="${2:-/work/recipes}"
LIB="$SRC/src/libaccountsservice"

# --- (0) pin the project version --------------------------------------------
# generate-version.sh derives the version from the `accountsservice-<ver>` dir name (and
# git), but Procursus EXTRACT_TAR renames the tree to plain `accountsservice`, so the probe
# exits 1 ("Version unknown"). Replace it with a fixed echo.
printf '#!/bin/sh\necho 23.13.9\n' > "$SRC/generate-version.sh"
chmod +x "$SRC/generate-version.sh"

# --- (0b) bypass the wtmp-path probe (daemon-only; asserts on Darwin) ---------
# meson.build detects the wtmp filename for the daemon's login-record watcher. The Darwin
# branch cc.run()s (impossible in cross) or asserts /var/log/utx.log exists. The daemon is
# dropped, so PATH_WTMP is irrelevant - replace the whole probe with a placeholder.
if grep -q "Do not know which filename to watch for wtmp" "$SRC/meson.build"; then
  python3 - "$SRC/meson.build" <<'PY'
import sys
f = sys.argv[1]
s = open(f).read()
start = s.index("if cc.has_header_symbol('utmpx.h', 'WTMPX_FILENAME'")
anchor = s.index("Do not know which filename to watch for wtmp", start)
end = s.index("endif", anchor) + len("endif")
repl = ("# iOS: wtmp watching is a daemon feature (dropped); placeholder path.\n"
        "path_wtmp = '/var/log/wtmp'\n"
        "config_h.set_quoted('PATH_WTMP', path_wtmp)")
s = s[:start] + repl + s[end:]
open(f, "w").write(s)
print("bypassed wtmp probe")
PY
fi

# --- (1) stage the sd-login shim + header -------------------------------------
mkdir -p "$SRC/systemd"
cp "$RECIPES/accountsservice-sd-login.h"      "$SRC/systemd/sd-login.h"
cp "$RECIPES/accountsservice-sd-login-shim.c" "$LIB/xios-sd-login-shim.c"

# --- (2) drop the accounts-daemon (Linux-only) from src/meson.build -----------
# Remove the block from the second `sources = files(` through the `daemon = executable(...)`
# call, keeping libaccounts_generated (the codegen static lib the client library links) and
# the trailing `subdir('libaccountsservice')`.
if grep -q "daemon = executable" "$SRC/src/meson.build"; then
  python3 - "$SRC/src/meson.build" <<'PY'
import re, sys
f = sys.argv[1]
s = open(f).read()
# cut from the SECOND "sources = files(" up to and including the "daemon = executable(...)" call.
start = s.index("sources = files(", s.index("sources = []"))
# the daemon executable() call ends at the first ")" line after "install_dir: act_libexecdir,"
end = s.index("act_libexecdir,", start)
end = s.index(")", end) + 1
s = s[:start] + "# iOS: accounts-daemon dropped (utmp/crypt/shadow are Linux-only).\n" + s[end:]
open(f, "w").write(s)
print("dropped accounts-daemon from src/meson.build")
PY
fi

# --- (2b) drop the tests subdir (references the dropped `daemon`) --------------
sed -i "/^subdir('tests')$/d" "$SRC/meson.build"

# --- (2c) drop the polkit .policy generation (daemon-only) --------------------
# i18n.merge_file on the .policy.in needs the polkit gettext ITS rules on the HOST
# (msgfmt: "cannot locate ITS rules"), and the policy only matters to the daemon we drop.
if grep -q "policy + '.in'" "$SRC/data/meson.build"; then
  python3 - "$SRC/data/meson.build" <<'PY'
import sys
f = sys.argv[1]
s = open(f).read()
start = s.index("policy = act_namespace.to_lower()")
anchor = s.index("install_dir: policy_dir,", start)
end = s.index(")", anchor) + 1
s = s[:start] + "# iOS: polkit .policy dropped (daemon-only; needs host polkit ITS rules).\n" + s[end:]
open(f, "w").write(s)
print("dropped polkit .policy generation")
PY
fi

# --- (3) wire the shim into the library + drop logind/crypt -------------------
# add the shim source to the library
if ! grep -q "xios-sd-login-shim.c" "$LIB/meson.build"; then
  perl -0pi -e "s/sources = files\(\n  'act-user\.c',\n  'act-user-manager\.c',\n\)/sources = files(\n  'act-user.c',\n  'act-user-manager.c',\n  'xios-sd-login-shim.c',\n)/m" "$LIB/meson.build"
fi
# drop logind_dep from the library's dependency list (crypt_dep stays: libxcrypt is
# present and act-user.c's set_password helper links crypt_gensalt).
sed -i '/^  logind_dep,$/d' "$LIB/meson.build"

# --- (4) neutralize the top-level logind/libsystemd probe (required, would fail) ----
perl -0pi -e "s/if get_option\('elogind'\)\n  logind_dep = dependency\('libelogind', version: '>= 229\.4'\)\nelse\n  logind_dep = dependency\('libsystemd', version: '>= 186'\)\nendif/# iOS: no logind; libaccountsservice links a single-session sd-login shim instead.\nlogind_dep = declare_dependency()/m" "$SRC/meson.build"

# --- verification --------------------------------------------------------------
fail=0
check()  { grep -q "$2" "$1" || { echo "!! VERIFY FAILED: $1: missing $2"; fail=1; }; }
absent() { grep -q "$2" "$1" && { echo "!! VERIFY FAILED: $1: still has $2"; fail=1; } || true; }
check  "$SRC/systemd/sd-login.h" "sd_get_sessions"
check  "$LIB/xios-sd-login-shim.c" "XIOS_SEAT_ID"
check  "$LIB/meson.build" "xios-sd-login-shim.c"
absent "$LIB/meson.build" "logind_dep,"
absent "$SRC/src/meson.build" "daemon = executable"
absent "$SRC/meson.build" "subdir('tests')"
check  "$SRC/meson.build" "logind_dep = declare_dependency()"
[ "$fail" = 0 ] && echo "accountsservice-ios-fixes: all patches applied + verified" || exit 1
