#!/usr/bin/env bash
# gir-build-gnome-shell-ondevice.sh — generate the GNOME Shell introspection typelibs
# (St-14, Shell-14, Gvc-1.0, Shew-0) ON the iPad, by building gnome-shell 46.0 natively
# and letting its own meson build drive g-ir-scanner. St/Shell build INSIDE the
# gnome-shell tree, so this is the whole shell-side gir surface.
#
# This is gir-build-mutter-ondevice.sh applied to gnome-shell. The SAME source patch set
# as the cross build applies (recipes/gnome-shell-ios-fixes.sh — scp'd over and run
# on-device): EDS stays patched out, and the gir blocks are gated on
# `not meson.is_cross_build()` — a native build takes the gir path automatically.
#
# PREREQUISITES on the device (install via main's device window first):
#   1. The gnome-shell chain runtime+dev debs: libmutter-14-0/-dev, gjs/libgjs0/-dev,
#      at-spi2-core(+libatspi2.0-0/libatk-bridge2.0-0)/-dev, libgcr-4-4/gcr4-dev,
#      libpolkit-{gobject,agent}-1-0/polkit-dev, libibus-1.0-5/libibus-dev,
#      libpulse0/libpulse-dev, libstartup-notification0/-dev, libgnome-desktop-4-2/-dev,
#      gtk3/gtk4 -dev, gsettings-desktop-schemas, dconf, dbus.
#   2. The on-device GI toolchain bootstrapped (gir-ondevice.sh bootstrap): g-ir-scanner,
#      sljit_shim.dylib, clang-ios, ninja2 — per memory x11-gtk4-typelibs-ondevice.
#   3. Dependency girs installed in /var/jb/usr/share/gir-1.0: the GTK4 set + the mutter
#      set (Meta-14, Clutter-14, Cogl-14, Mtk-14, Cally-14 — gir-build-mutter-ondevice.sh)
#      + Gcr-4/PolkitAgent-1.0 are NOT needed as girs — wait, they ARE gir includes of
#      Shell-14: install gir1.2 equivalents by also running the dep scans if the scan
#      fails on missing Gcr-4/PolkitAgent-1.0 (see NOTE below).
#   4. Native build tools: meson, ninja, clang, glib tools, gettext, pkg-config, perl
#      (data-to-c.pl), python3.
#
# NOTE the Shell-14 scan --include's Gcr-4 and PolkitAgent-1.0, whose girs don't exist
# yet (gcr/polkit were cross-built introspection-off). If the Shell scan fails on those,
# first generate them on-device with the same pattern (each project's own native meson
# build: gcr -Dintrospection=true; polkit -Dintrospection=true -Dlibs-only=true + the
# polkitagent meson patch from recipes/polkit.mk), then re-run this script. St-14 has no
# Gcr/Polkit includes and builds regardless — enough for St/theme work in the meantime.
#
# Usage (from the Mac build host):
#   DEVICE=root@MaxsiPad.local ./gir-build-gnome-shell-ondevice.sh /path/to/gnome-shell-46.0.tar
# (decompress the .tar.xz locally first — the device has no xz.)
set -euo pipefail

DEVICE="${DEVICE:-root@MaxsiPad.local}"
SSHKEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=20 -o IdentitiesOnly=yes -i "$SSHKEY" "$DEVICE")
SCP=(scp -o BatchMode=yes -o ConnectTimeout=20 -o IdentitiesOnly=yes -i "$SSHKEY")

TAR="${1:?usage: gir-build-gnome-shell-ondevice.sh <gnome-shell-46.0.tar>}"
BASE="$(basename "$TAR" .tar)"   # gnome-shell-46.0
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK=/var/jb/tmp/gnome-shell-gir
GISPIKE=/var/jb/tmp/gi-spike     # sljit_shim.dylib, clang-ios, ninja2 (gir-ondevice.sh bootstrap)

echo "==> [$BASE] pushing source + fixes script to device"
"${SSH[@]}" "mkdir -p $WORK"
"${SCP[@]}" "$TAR" "$HERE/recipes/gnome-shell-ios-fixes.sh" "$DEVICE:$WORK/" >/dev/null

echo "==> [$BASE] native build + install shell typelibs on-device"
# shellcheck disable=SC2087
"${SSH[@]}" "BASE='$BASE' bash -s" <<'EOSH'
set -e
WORK=/var/jb/tmp/gnome-shell-gir
GISPIKE=/var/jb/tmp/gi-spike
PREFIX=/var/jb/usr

# --- on-device build environment (the gir-ondevice.sh frictions) ---
export DYLD_LIBRARY_PATH=$PREFIX/lib
export DYLD_INSERT_LIBRARIES=$GISPIKE/sljit_shim.dylib   # pcre2 flat-namespace shim for giscanner
export CC=$GISPIKE/clang-ios                             # force -target arm64-apple-ios
export CXX=$GISPIKE/clang-ios
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig
export GI_TYPELIB_PATH=$PREFIX/lib/girepository-1.0:$PREFIX/lib/mutter-14
export XDG_DATA_DIRS=$PREFIX/share
export PATH=$PREFIX/bin:/var/jb/bin:/usr/bin:/bin
export M4=$PREFIX/bin/m4
NINJA=$GISPIKE/ninja2                                    # ninja byte-patched /bin/sh -> /var/sh
[ -e /var/sh ] || ln -sf /var/jb/bin/sh /var/sh

cd $WORK
rm -rf "$BASE"
tar xf "$BASE.tar"

# Same patch set as the cross build (EDS out, gir blocks native-gated, device gjs path).
bash gnome-shell-ios-fixes.sh "$WORK/$BASE" /var/jb/usr/bin/gjs

cd "$BASE"
echo "--- meson setup (native; girs enabled via the is_cross_build gate) ---"
meson setup _build --prefix=$PREFIX \
  -Dnetworkmanager=false -Dcamera_monitor=false -Dsystemd=false \
  -Dextensions_tool=false -Dextensions_app=false \
  -Dtests=false -Dman=false -Dgtk_doc=false 2>&1 | tail -8

echo "--- ninja: typelib targets only (still builds libst/libshell/libgvc/libshew) ---"
TL=$($NINJA -C _build -t targets all 2>/dev/null | sed -n 's/:.*//p' | grep -E '\.typelib$' || true)
echo "typelib targets: $TL"
$NINJA -C _build $TL 2>&1 | tail -20

echo "--- install produced gir + typelib ---"
GIRS=$(find _build -name '*.gir'); TLS=$(find _build -name '*.typelib')
[ -n "$TLS" ] || { echo "!! NO TYPELIB PRODUCED"; exit 3; }
mkdir -p $PREFIX/share/gir-1.0 $PREFIX/lib/girepository-1.0
for g in $GIRS; do cp -v "$g" $PREFIX/share/gir-1.0/; done
for t in $TLS;  do cp -v "$t" $PREFIX/lib/girepository-1.0/; done
echo "--- installed namespaces ---"; for t in $TLS; do basename "$t" .typelib; done
EOSH

echo "==> [$BASE] validate gjs can import St-14"
"${SSH[@]}" bash -s <<'EOSH'
export DYLD_LIBRARY_PATH=/var/jb/usr/lib
export GI_TYPELIB_PATH=/var/jb/usr/lib/girepository-1.0:/var/jb/usr/lib/mutter-14
gjs -c 'imports.gi.versions.St="14"; const St = imports.gi.St; print("imports.gi.St OK: " + typeof St.Widget);' \
  && echo "==> MILESTONE: gjs loads St-14" || echo "!! gjs St import FAILED"
EOSH
echo "==> done"
