#!/usr/bin/env bash
# gir-build-accountsservice-ondevice.sh — generate the AccountsService-1.0 typelib ON the
# iPad, by building libaccountsservice 23.13.9 natively with -Dintrospection=true and letting
# its own meson build drive g-ir-scanner.
#
# WHY this is boot-critical: gnome-shell's panel.js -> status/system.js -> js/misc/
# systemActions.js does a STATIC top-level `import AccountsService from 'gi://AccountsService'`.
# panel.js loads at boot, so gjs throws at module-load if the AccountsService-1.0 typelib is
# missing and the shell crashes building the top panel. accountsservice is NOT a gnome-shell
# build dep (runtime gi:// import only), so this typelib must be generated ALONGSIDE St/Shell
# (see gir-build-gnome-shell-ondevice.sh) before the shell will boot. (Reported by gnome-session.)
#
# This is the Design-A (gir-build-mutter-ondevice.sh) pattern applied to a standalone lib:
# cross can't run the gir dumper on a Mach-O binary, so the scan happens on the device. We
# build the lib's own meson with introspection ON and let it emit the exact scanner command.
# The accountsservice.mk cross build was -Dintrospection=false for exactly this reason; the
# runtime dylib + headers ship in the libaccountsservice0 / -dev debs.
#
# PREREQUISITES on the device (install via main's device window first):
#   1. libaccountsservice0 + libaccountsservice-dev installed (dylib + headers + accountsservice.pc).
#   2. The on-device GI toolchain bootstrapped (gir-ondevice.sh bootstrap): g-ir-scanner,
#      sljit_shim.dylib, clang-ios, ninja2 — per memory x11-gtk4-typelibs-ondevice.
#   3. Dependency girs installed in /var/jb/usr/share/gir-1.0: GObject-2.0 + Gio-2.0
#      (gir1.2-glib-2.0) — the AccountsService scan --include's exactly these two.
#   4. Native build tools: meson, ninja, clang, glib-mkenums, gdbus-codegen, pkg-config, perl.
#   5. polkit-dev on device (accountsservice's meson dependency()s polkit-gobject-1 for the
#      library even with the daemon dropped).
#
# The source-port fixes are gnome-session's (recipes/accountsservice-ios-fixes.sh +
# accountsservice-sd-login.h + accountsservice-sd-login-shim.c); this script scp's all three
# and applies them exactly like the cross build, then flips introspection ON.
#
# Usage (from the Mac build host):
#   DEVICE=root@MaxsiPad.local ./gir-build-accountsservice-ondevice.sh /path/to/accountsservice-23.13.9.tar
# (decompress the .tar.xz locally first — the device has no xz.)
set -euo pipefail

DEVICE="${DEVICE:-root@MaxsiPad.local}"
SSHKEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=20 -o IdentitiesOnly=yes -i "$SSHKEY" "$DEVICE")
SCP=(scp -o BatchMode=yes -o ConnectTimeout=20 -o IdentitiesOnly=yes -i "$SSHKEY")

TAR="${1:?usage: gir-build-accountsservice-ondevice.sh <accountsservice-23.13.9.tar>}"
BASE="$(basename "$TAR" .tar)"   # accountsservice-23.13.9
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK=/var/jb/tmp/accountsservice-gir
GISPIKE=/var/jb/tmp/gi-spike     # sljit_shim.dylib, clang-ios, ninja2 (gir-ondevice.sh bootstrap)

echo "==> [$BASE] pushing source + gnome-session fix files to device"
"${SSH[@]}" "mkdir -p $WORK"
"${SCP[@]}" "$TAR" \
  "$HERE/recipes/accountsservice-ios-fixes.sh" \
  "$HERE/recipes/accountsservice-sd-login.h" \
  "$HERE/recipes/accountsservice-sd-login-shim.c" \
  "$DEVICE:$WORK/" >/dev/null

echo "==> [$BASE] native introspection build + install typelib on-device"
# shellcheck disable=SC2087
"${SSH[@]}" "BASE='$BASE' bash -s" <<'EOSH'
set -e
WORK=/var/jb/tmp/accountsservice-gir
GISPIKE=/var/jb/tmp/gi-spike
PREFIX=/var/jb/usr

# --- on-device build environment (the gir-ondevice.sh frictions) ---
export DYLD_LIBRARY_PATH=$PREFIX/lib
export DYLD_INSERT_LIBRARIES=$GISPIKE/sljit_shim.dylib   # pcre2 flat-namespace shim for giscanner
export CC=$GISPIKE/clang-ios                             # force -target arm64-apple-ios
export CXX=$GISPIKE/clang-ios
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig
export GI_TYPELIB_PATH=$PREFIX/lib/girepository-1.0
export XDG_DATA_DIRS=$PREFIX/share
export PATH=$PREFIX/bin:/var/jb/bin:/usr/bin:/bin
export M4=$PREFIX/bin/m4
NINJA=$GISPIKE/ninja2                                    # ninja byte-patched /bin/sh -> /var/sh
[ -e /var/sh ] || ln -sf /var/jb/bin/sh /var/sh

cd $WORK
rm -rf "$BASE"
tar xf "$BASE.tar"

# Same source-port fixes as the cross build (gnome-session's recipe), applied on-device.
bash accountsservice-ios-fixes.sh "$WORK/$BASE" "$WORK"

cd "$BASE"
echo "--- meson setup (introspection=true, native) ---"
meson setup _build --prefix=$PREFIX \
  -Dintrospection=true -Dvapi=false -Dsystemdsystemunitdir=no \
  -Ddocbook=false -Dgtk_doc=false 2>&1 | tail -8

echo "--- ninja: typelib target only (still builds libaccountsservice) ---"
TL=$($NINJA -C _build -t targets all 2>/dev/null | sed -n 's/:.*//p' | grep -E '\.typelib$' || true)
echo "typelib targets: $TL"
$NINJA -C _build $TL 2>&1 | tail -20

echo "--- install produced gir + typelib ---"
GIRS=$(find _build -name 'AccountsService*.gir'); TLS=$(find _build -name 'AccountsService*.typelib')
[ -n "$TLS" ] || { echo "!! NO AccountsService TYPELIB PRODUCED"; exit 3; }
mkdir -p $PREFIX/share/gir-1.0 $PREFIX/lib/girepository-1.0
for g in $GIRS; do cp -v "$g" $PREFIX/share/gir-1.0/; done
for t in $TLS;  do cp -v "$t" $PREFIX/lib/girepository-1.0/; done
echo "--- installed namespaces ---"; for t in $TLS; do basename "$t" .typelib; done
EOSH

echo "==> [$BASE] validate gjs can import AccountsService"
"${SSH[@]}" bash -s <<'EOSH'
export DYLD_LIBRARY_PATH=/var/jb/usr/lib
export GI_TYPELIB_PATH=/var/jb/usr/lib/girepository-1.0
gjs -c 'const AccountsService = imports.gi.AccountsService; print("imports.gi.AccountsService OK: " + typeof AccountsService.UserManager);' \
  && echo "==> MILESTONE: gjs loads AccountsService-1.0 (gnome-shell panel boot unblocked)" \
  || echo "!! gjs AccountsService import FAILED"
EOSH
echo "==> done"
