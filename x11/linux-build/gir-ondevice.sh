#!/usr/bin/env bash
# gir-ondevice.sh — generate GObject-Introspection typelibs ON the iPad.
#
# Why this exists: g-ir-scanner produces typelibs by compiling and RUNNING a probe
# linked against the target library. Cross-compiling, that probe is an iOS Mach-O
# binary qemu can't execute — the classic GI cross wall (gnome-plan.md Blocker #2).
# The escape is that the device is a full arm64 Darwin machine: Procursus apt ships
# clang/ld64/python3.9/meson/ninja/bison, so g-ir-scanner runs NATIVELY on-device and
# the probe is just a normal native binary. Proven 2026-06-30 (see docs/gjs-plan.md):
# built gobject-introspection 1.78 on-device and runtime-loaded GLib/GObject/Gio typelibs.
#
# Two subcommands:
#   bootstrap  — install the toolchain + build & install gobject-introspection on-device
#                (yields libgirepository + g-ir-scanner/compiler + GLib/GObject/Gio typelibs)
#   scan NS PKG [HEADER...] — scan one already-installed library (its -dev deb) into a
#                .gir + .typelib (e.g. `scan Gtk 4.0 gtk4 gtk/gtk.h`)
#
# Usage:
#   DEVICE=root@MaxsiPad.local ./gir-ondevice.sh bootstrap
#   DEVICE=root@MaxsiPad.local ./gir-ondevice.sh scan Gtk 4.0 gtk4
#
# Run from the build host (Mac). Needs ssh key auth to the device and the g-i tarball
# reachable (downloaded + xz-decompressed locally, because the device has no xz).
set -euo pipefail

DEVICE="${DEVICE:-root@MaxsiPad.local}"
SSH=(ssh -o BatchMode=yes -o IdentitiesOnly=yes -i "${SSH_KEY:-$HOME/.ssh/id_ed25519}" "$DEVICE")
SCP=(scp -o BatchMode=yes -o IdentitiesOnly=yes -i "${SSH_KEY:-$HOME/.ssh/id_ed25519}")
GI_VERSION="${GI_VERSION:-1.78.0}"          # pair with glib 2.78 / gjs 1.78
SCRATCH=/var/jb/tmp/gi-spike
PREFIX=/var/jb/usr

# --- the on-device environment every native build/scan needs (the 6 frictions) ---
#  * DYLD_LIBRARY_PATH: rootless dyld doesn't auto-search /var/jb/usr/lib
#  * DYLD_INSERT_LIBRARIES: shim the dangling pcre2 _SLJIT_UPDATE_WX_FLAGS so the
#    flat-namespace giscanner python ext can dlopen (iOS never calls it: no RWX)
#  * CC wrapper: on-device clang defaults to the macOS platform; force iOS target
#  * M4: Procursus bison has a wrong baked-in m4 path
DEV_ENV='export DYLD_LIBRARY_PATH=/var/jb/usr/lib:'"$SCRATCH"'/gobject-introspection-'"$GI_VERSION"'/_build/girepository:'"$SCRATCH"'/gobject-introspection-'"$GI_VERSION"'/_build/girepository/cmph; \
export DYLD_INSERT_LIBRARIES='"$SCRATCH"'/sljit_shim.dylib; \
export CC='"$SCRATCH"'/clang-ios CXX=clang++ M4=/var/jb/usr/bin/m4'

prep_device_common() {
  "${SSH[@]}" bash -s <<EOSH
set -e
mkdir -p $SCRATCH

# (5) shim the latent pcre2-JIT symbol that libpcre2-8 leaves as a flat-namespace undefined
if [ ! -f $SCRATCH/sljit_shim.dylib ]; then
  printf 'void SLJIT_UPDATE_WX_FLAGS(void*a,void*b,int c){(void)a;(void)b;(void)c;}\n' > $SCRATCH/sljit_shim.c
  clang -dynamiclib -o $SCRATCH/sljit_shim.dylib $SCRATCH/sljit_shim.c -install_name $SCRATCH/sljit_shim.dylib
  ldid -S $SCRATCH/sljit_shim.dylib
fi

# (6) one-token CC wrapper that forces the iOS platform (on-device clang defaults to macOS)
if [ ! -x $SCRATCH/clang-ios ]; then
  printf '#!/var/jb/bin/sh\nexec /var/jb/usr/bin/clang -target arm64-apple-ios14.0 "\$@"\n' > $SCRATCH/clang-ios
  chmod +x $SCRATCH/clang-ios
fi

# (2) ninja hardcodes /bin/sh (absent on rootless); /var/sh is a same-length symlink target
[ -e /var/sh ] || ln -sf /var/jb/bin/sh /var/sh
EOSH
}

cmd_bootstrap() {
  local tarxz="gobject-introspection-${GI_VERSION}.tar.xz"
  local tar="gobject-introspection-${GI_VERSION}.tar"
  echo "==> installing on-device toolchain + deps"
  "${SSH[@]}" 'export DEBIAN_FRONTEND=noninteractive; apt-get update >/dev/null 2>&1 || true; \
    apt-get install -y clang odcctools ld64 pkg-config python3 libpython3.9-dev meson ninja make \
      m4 flex bison libffi-dev libglib2.0-dev libpcre2-dev gettext'

  echo "==> staging g-i ${GI_VERSION} source (device has no xz, so push a plain .tar)"
  if [ ! -f "$tar" ]; then
    [ -f "$tarxz" ] || curl -fsSL -o "$tarxz" \
      "https://download.gnome.org/sources/gobject-introspection/${GI_VERSION%.*}/$tarxz"
    xz -dk -f "$tarxz"
  fi
  "${SCP[@]}" "$tar" "$DEVICE:$SCRATCH/"

  prep_device_common

  echo "==> byte-patch a ninja copy: /bin/sh -> /var/sh (same length) + re-sign"
  "${SSH[@]}" bash -s <<EOSH
set -e
cp -f /var/jb/usr/bin/ninja $SCRATCH/ninja2
python3 - <<PY
d=open("$SCRATCH/ninja2","rb").read().replace(b"/bin/sh\x00",b"/var/sh\x00")
open("$SCRATCH/ninja2","wb").write(d)
PY
chmod +x $SCRATCH/ninja2; ldid -S $SCRATCH/ninja2
cd $SCRATCH && rm -rf gobject-introspection-$GI_VERSION && tar xf $tar
cd gobject-introspection-$GI_VERSION
$DEV_ENV
meson setup _build --prefix=$PREFIX -Dbuild_introspection_data=true \
  -Dcairo=disabled -Ddoctool=disabled -Dgtk_doc=false
$SCRATCH/ninja2 -C _build
echo "==> typelibs:"; ls _build/gir/*.typelib
EOSH
  echo "==> bootstrap done. Install with: ${SSH[*]} 'cd $SCRATCH/gobject-introspection-$GI_VERSION && $SCRATCH/ninja2 -C _build install'"
}

# scan one installed library:  scan <Namespace> <Version> <pkg-config-name> [extra header...]
cmd_scan() {
  local ns="$1" ver="$2" pkg="$3"; shift 3
  echo "==> scanning $ns-$ver from pkg '$pkg' on-device"
  prep_device_common
  "${SSH[@]}" bash -s <<EOSH
set -e
cd $SCRATCH
$DEV_ENV
# Per-library scanning uses no ninja/bison/m4 — only the dyld path, the shim, and the CC wrapper.
g-ir-scanner --namespace=$ns --nsversion=$ver --output=$ns-$ver.gir \\
  --warn-all --no-libtool \\
  \$(pkg-config --cflags --libs $pkg) \\
  \$(for h in $*; do echo /var/jb/usr/include/\$h; done) \\
  --cc=$SCRATCH/clang-ios
g-ir-compiler $ns-$ver.gir -o $ns-$ver.typelib
echo "==> produced:"; ls -la $SCRATCH/$ns-$ver.gir $SCRATCH/$ns-$ver.typelib
EOSH
}

case "${1:-}" in
  bootstrap) cmd_bootstrap ;;
  scan) shift; cmd_scan "$@" ;;
  *) echo "usage: $0 {bootstrap | scan <Namespace> <Version> <pkg> [header...]}" >&2; exit 2 ;;
esac
