#!/usr/bin/env bash
# gir-build-ondevice.sh — build a meson library ON the iPad with introspection ENABLED,
# yielding native-correct .gir/.typelib, then install them into the device's GI search dirs.
#
# Why this and not gir-ondevice.sh's `scan`: the GTK stack's g-ir-scanner invocations are
# enormous (per-namespace header filelists, identifier/symbol prefixes, --include chains,
# generated enum headers) and brittle to hand-write. Instead each library's own meson build
# drives g-ir-scanner natively on the device, so the dumper meson compiles is native arm64
# Mach-O running against the real installed ABI — no cross, no qemu, no ssh dumper-shuttle.
#
# The library's runtime deb must already be installed on-device (we link/scan the build-tree
# copy, but its deps resolve from the installed prefix), plus its -dev headers and every
# dependency namespace's .gir (so --include resolves). Build dependency order:
#   graphene, harfbuzz, gdk-pixbuf, pango, gtk4 (Gdk/Gsk/Gtk), libadwaita.
#
# Device prerequisites (one-time, beyond gir-ondevice.sh bootstrap):
#   1. The lib's runtime + -dev debs installed (headers + .pc), plus their -dev deps pulled
#      via `apt-get install -f` (freetype/png/pixman/x11/uuid/jpeg/tiff/...).
#   2. The FULL target pkg-config set merged onto the device (cp -n from the Docker build
#      sysroot build_base/iphoneos-arm64-rootless/.../usr/{lib,share}/pkgconfig). The per-deb
#      headers don't carry every transitive .pc (expat, xcb-render/shm, ...), and cairo/gtk4
#      have long Requires.private chains. zlib.pc is auto-created below (iOS ships no zlib.pc).
#
# Usage (run from the build host / Mac):
#   DEVICE=root@MaxsiPad.local ./gir-build-ondevice.sh <local-source.tar> [meson -D opts...]
#   GIR_PREBUILD='<shell snippet>' ... ./gir-build-ondevice.sh ...  # patch source pre-setup
# e.g.
#   ./gir-build-ondevice.sh scratchpad/src/graphene-1.10.8.tar \
#       -Dintrospection=enabled -Dgobject_types=true -Dtests=false -Dgtk_doc=false
#
# After build it copies every produced *.gir -> /var/jb/usr/share/gir-1.0 and
# *.typelib -> /var/jb/usr/lib/girepository-1.0, then lists the new namespaces.
set -euo pipefail

DEVICE="${DEVICE:-root@MaxsiPad.local}"
SSHKEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=20 -o IdentitiesOnly=yes -i "$SSHKEY" "$DEVICE")
SCP=(scp -o BatchMode=yes -o ConnectTimeout=20 -o IdentitiesOnly=yes -i "$SSHKEY")

TAR="${1:?usage: gir-build-ondevice.sh <source.tar> [meson opts...]}"; shift
MESON_OPTS="$*"
BASE="$(basename "$TAR" .tar)"            # e.g. graphene-1.10.8
# Optional source patch run in the extracted dir before meson setup (e.g. neutralise a
# darwin-only dep). Set via env GIR_PREBUILD='shell snippet'. base64-passed so arbitrary
# quoting (sed with single quotes/brackets) survives ssh command flattening.
PREBUILD_B64="$(printf '%s' "${GIR_PREBUILD:-}" | base64 | tr -d '\n')"
WORK=/var/jb/tmp/gir-build
GISPIKE=/var/jb/tmp/gi-spike              # provides sljit_shim.dylib, clang-ios, ninja2 (gir-ondevice.sh bootstrap)

echo "==> [$BASE] pushing source"
"${SSH[@]}" "mkdir -p $WORK"
"${SCP[@]}" "$TAR" "$DEVICE:$WORK/" >/dev/null

echo "==> [$BASE] build (introspection) + install gir/typelib on-device"
# NOTE: ssh flattens the remote command into one string, so positional args lose their
# quoting (a multi-word "$MESON_OPTS" would split). Pass BASE/MESON_OPTS as exported env
# vars in the remote command prefix instead — single-quoted, safe (no quotes in the values).
# shellcheck disable=SC2087
"${SSH[@]}" "BASE='$BASE' MESON_OPTS='$MESON_OPTS' PREBUILD_B64='$PREBUILD_B64' bash -s" <<'EOSH'
set -e
WORK=/var/jb/tmp/gir-build
GISPIKE=/var/jb/tmp/gi-spike
# --- the on-device build environment (the same frictions gir-ondevice.sh documents) ---
export DYLD_LIBRARY_PATH=/var/jb/usr/lib          # rootless dyld doesn't auto-search the prefix
export DYLD_INSERT_LIBRARIES=$GISPIKE/sljit_shim.dylib  # pcre2 flat-namespace shim for giscanner
export CC=$GISPIKE/clang-ios                      # force -target arm64-apple-ios (clang defaults macOS)
export PKG_CONFIG_PATH=/var/jb/usr/lib/pkgconfig:/var/jb/usr/share/pkgconfig
export GI_TYPELIB_PATH=/var/jb/usr/lib/girepository-1.0
export PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin
export M4=/var/jb/usr/bin/m4
NINJA=$GISPIKE/ninja2                              # ninja byte-patched /bin/sh -> /var/sh

# iOS provides zlib via the system (libz in the dyld cache) but ships no zlib.pc. freetype2.pc
# has `Requires.private: zlib`, so any pkg-config resolution that walks freetype (harfbuzz,
# pango, gtk4) fails without it. Drop a minimal pc once (idempotent).
if [ ! -f /var/jb/usr/lib/pkgconfig/zlib.pc ]; then
  cat > /var/jb/usr/lib/pkgconfig/zlib.pc <<PC
prefix=/var/jb/usr
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include

Name: zlib
Description: zlib compression library (iOS system libz shim pc)
Version: 1.2.12
Libs: -L\${libdir} -lz
Cflags:
PC
fi

cd $WORK
rm -rf "$BASE"
tar xf "$BASE.tar"
cd "$BASE"
if [ -n "$PREBUILD_B64" ]; then
  echo "--- prebuild patch ---"
  eval "$(printf '%s' "$PREBUILD_B64" | base64 -d)"
fi
echo "--- meson setup ($MESON_OPTS) ---"
meson setup _build --prefix=/var/jb/usr $MESON_OPTS 2>&1 | tail -6
echo "--- ninja (typelib targets only: skips tests/tools/demos and unrelated libs e.g. hb-subset) ---"
TL_TARGETS=$($NINJA -C _build -t targets all 2>/dev/null | sed -n 's/:.*//p' | grep -E '\.typelib$' || true)
if [ -n "$TL_TARGETS" ]; then
  echo "targets: $TL_TARGETS"
  $NINJA -C _build $TL_TARGETS 2>&1 | tail -10
else
  echo "(no typelib target found; building all)"; $NINJA -C _build 2>&1 | tail -10
fi
echo "--- produced introspection artifacts ---"
GIRS=$(find _build -name '*.gir')
TLS=$(find _build -name '*.typelib')
[ -n "$GIRS" ] || { echo "!! NO GIR PRODUCED"; exit 3; }
for g in $GIRS;  do cp -v "$g" /var/jb/usr/share/gir-1.0/; done
for t in $TLS;   do cp -v "$t" /var/jb/usr/lib/girepository-1.0/; done
echo "--- installed namespaces ---"
for t in $TLS; do basename "$t" .typelib; done
EOSH

echo "==> [$BASE] done"
