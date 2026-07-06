#!/usr/bin/env bash
# build-gjs-manual.sh — stage gjs 1.78's deps into procursus-vol-gjs and cross-build gjs against
# the working libmozjs-115 (the deps are prebuilt/staged, not recipe-built, so we drive meson
# directly). Run in the container:
#   docker run --rm --platform linux/arm64 --cpus=3 --entrypoint /usr/bin/bash \
#     -v procursus-vol-gjs:/work/Procursus -v procursus-vol-gtk:/from:ro -v "$PWD/out:/out:ro" \
#     -v "$PWD/../ports:/work/ports:ro" \
#     -v "$PWD/build-gjs-manual.sh:/work/b.sh:ro" procursus-xbuild:bookworm-arm64 /work/b.sh
#
# State as of handoff (2026-06-30): configure was reached with ALL deps resolving incl mozjs-115;
# the two dep gaps below are FIXED here (verified): (1) cairo's X-proto .pc live in
# build_base/share/pkgconfig — must be on PKG_CONFIG_LIBDIR; (2) gjs's readline find_library link
# probe needs -stdlib=libc++ (iOS). The previous detached "gjs-build" container FAILED before
# these fixes — relaunch from THIS script.
set -euo pipefail
export PATH="/root/cctools/bin:$PATH"
TS=/work/Procursus/build_base/iphoneos-arm64-rootless/1900
B=$TS/var/jb/usr

if ! command -v glib-compile-schemas >/dev/null 2>&1 || ! command -v glib-compile-resources >/dev/null 2>&1; then
  echo "==> installing host GLib codegen tools"
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends libglib2.0-bin libglib2.0-dev-bin >/dev/null 2>&1
fi

# --- 1. stage deps (idempotent) -------------------------------------------------------------
if [ ! -f "$B/lib/pkgconfig/glib-2.0.pc" ] && [ -d /from ]; then
  echo "==> staging glib/cairo + transitive deps from procursus-vol-gtk"
  cp -a /from/build_base/iphoneos-arm64-rootless/1900/var/jb/usr/. "$B/"
fi
if [ ! -f "$B/lib/libgirepository-1.0.1.dylib" ] && [ -d /out ]; then
  echo "==> dpkg-extract gir + mozjs debs into build_base"
  for pat in libgirepository-1.0-1 libgirepository-1.0-dev libmozjs-115-0 libmozjs-115-dev; do
    d=$(ls /out/${pat}_*.deb 2>/dev/null | head -1); [ -n "$d" ] && dpkg-deb -x "$d" "$TS"
  done
fi
# mozjs ships js.pc; gjs wants mozjs-115.pc. Rewrite this every run: the first
# manual pass injected js/RequiredDefines.h, which is not shipped by mozjs115.
cat > "$B/lib/pkgconfig/mozjs-115.pc" <<EOF
prefix=/var/jb/usr
includedir=\${prefix}/include
libdir=\${prefix}/lib
Name: SpiderMonkey 115
Description: The Mozilla library for JavaScript
Version: 115.12.0
Libs: -L\${libdir} -lmozjs-115
Cflags: -I\${includedir}/mozjs-115 -fno-rtti -fno-exceptions
EOF

# FIX 1: cairo's X-backend Requires.private (.pc in share/pkgconfig)
export PKG_CONFIG_LIBDIR=$B/lib/pkgconfig:$B/share/pkgconfig
export PKG_CONFIG_SYSROOT_DIR=$TS

# --- 2. cross toolchain wrappers ------------------------------------------------------------
G=/work/Procursus/gjs-build; mkdir -p $G; cd $G
cat > cc <<EOF
#!/bin/sh
exec aarch64-apple-darwin-clang "\$@" -L$B/lib -Wl,-rpath,/var/jb/usr/lib -Wno-unused-command-line-argument
EOF
# FIX 2: gjs is C++ → iOS needs libc++ (else the readline find_library probe fails on -lstdc++)
cat > cxx <<EOF
#!/bin/sh
exec aarch64-apple-darwin-clang++ "\$@" -stdlib=libc++ -L$B/lib -Wl,-rpath,/var/jb/usr/lib -Wno-unused-command-line-argument
EOF
chmod +x cc cxx

# --- 3. fetch + configure + build gjs -------------------------------------------------------
[ -f gjs-1.78.0.tar.xz ] || curl -fsSLo gjs-1.78.0.tar.xz https://download.gnome.org/sources/gjs/1.78/gjs-1.78.0.tar.xz
rm -rf gjs-1.78.0; tar xf gjs-1.78.0.tar.xz; cd gjs-1.78.0
PATCH_DIR="${GJS_PATCH_DIR:-/work/ports/gjs/patches}"
if [ ! -f "$PATCH_DIR/series" ]; then
  echo "ERROR: missing $PATCH_DIR/series; mount ports with -v \\$PWD/../ports:/work/ports:ro or set GJS_PATCH_DIR." >&2
  exit 1
fi
while IFS= read -r patch_name; do
  patch_name="${patch_name%%#*}"
  patch_name="${patch_name## }"
  patch_name="${patch_name%% }"
  [ -n "$patch_name" ] || continue
  patch -p1 < "$PATCH_DIR/$patch_name"
done < "$PATCH_DIR/series"
cat > cross.txt <<EOF
[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
[properties]
needs_exe_wrapper = true
[built-in options]
prefix = '/var/jb/usr'
[binaries]
c = '$G/cc'
cpp = '$G/cxx'
pkgconfig = 'pkg-config'
EOF
meson setup _build --cross-file cross.txt \
  -Dprofiler=disabled -Dinstalled_tests=false -Dskip_dbus_tests=true \
  -Dskip_gtk_tests=true -Dbsymbolic_functions=false -Dreadline=disabled 2>&1 | tail -25
[ -f _build/build.ninja ] || { echo "CONFIGURE_FAILED"; exit 1; }
echo "==> CONFIGURE_OK; building"
ninja -C _build 2>&1 | tee $G/gjs-build.log | tail -25
NINJA_EXIT=${PIPESTATUS[0]}
echo "NINJA_EXIT=$NINJA_EXIT"
[ "$NINJA_EXIT" -eq 0 ] || exit "$NINJA_EXIT"
find _build \( -name 'libgjs*.dylib' -o -name 'gjs-console' \) 2>/dev/null

# --- 4. install + package -------------------------------------------------------------------
STAGE=$G/stage
DEBROOT=$G/debs
OUT=${OUT:-/out}
V=1.78.0
ARCH=iphoneos-arm64
MAINT="Max Leiter <maxwell.leiter@gmail.com>"
P=/var/jb/usr

rm -rf "$STAGE" "$DEBROOT"
mkdir -p "$STAGE" "$DEBROOT" "$OUT"
DESTDIR="$STAGE" meson install -C _build --no-rebuild

sign_tree() {
  root=$1
  command -v ldid >/dev/null 2>&1 || return 0
  find "$root" -type f \( -name '*.dylib' -o -name '*.so' -o -perm -111 \) \
    -exec ldid -S {} \; 2>/dev/null || true
}

pick() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 && { echo "$c"; return; }
  done
  return 1
}

fix_gtkintl_loads() {
  root=$1
  int_tool=$(pick aarch64-apple-darwin-install_name_tool install_name_tool llvm-install-name-tool llvm-install-name-tool-14 || true)
  [ -n "${int_tool:-}" ] || return 0
  while IFS= read -r f; do
    grep -a -q '@rpath/libintl.dylib' "$f" 2>/dev/null || continue
    echo "==> relink $(basename "$f"): libintl -> libgtkintl"
    "$int_tool" -change @rpath/libintl.dylib @rpath/libgtkintl.dylib "$f" 2>/dev/null || true
    "$int_tool" -change @rpath/libintl.8.dylib @rpath/libgtkintl.dylib "$f" 2>/dev/null || true
  done < <(find "$root" -type f)
}

mkctrl() { # $1=pkgdir $2=pkgname $3=section $4=depends $5=shortdesc
  mkdir -p "$1/DEBIAN"
  cat > "$1/DEBIAN/control" <<EOF
Package: $2
Version: $V
Architecture: $ARCH
Maintainer: $MAINT
Depends: $4
Section: $3
Priority: optional
Homepage: https://gitlab.gnome.org/GNOME/gjs
Description: $5
 GNOME JavaScript bindings for the X11/GNOME-on-iOS stack.
EOF
}

build_deb() { # $1=pkgname
  fix_gtkintl_loads "$DEBROOT/$1$P"
  sign_tree "$DEBROOT/$1$P"
  dpkg-deb -Zxz -b "$DEBROOT/$1" "$OUT/${1}_${V}_${ARCH}.deb"
}

echo "==> package libgjs0"
D=$DEBROOT/libgjs0
mkdir -p "$D$P/lib"
find "$STAGE$P/lib" -maxdepth 1 \( -name 'libgjs.*.dylib' -o -name 'libgjs-*.dylib' \) \
  -exec cp -a {} "$D$P/lib/" \;
if [ ! "$(find "$D$P/lib" -type f -name 'libgjs*.dylib' -print -quit)" ]; then
  echo "ERROR: no versioned libgjs dylib found under $STAGE$P/lib"
  find "$STAGE$P/lib" -maxdepth 2 -type f | sort
  exit 1
fi
mkctrl "$D" libgjs0 Libraries \
  "libgtkintl, libglib2.0-0, libgirepository-1.0-1, libmozjs-115-0, libcairo2, libffi8" \
  "JavaScript bindings for GNOME (runtime library)"
build_deb libgjs0

echo "==> package gjs"
D=$DEBROOT/gjs
mkdir -p "$D$P"
[ -d "$STAGE$P/bin" ] && cp -a "$STAGE$P/bin" "$D$P/"
[ -d "$STAGE$P/share/gjs-1.0" ] && { mkdir -p "$D$P/share"; cp -a "$STAGE$P/share/gjs-1.0" "$D$P/share/"; }
[ -d "$STAGE$P/lib/gjs" ] && { mkdir -p "$D$P/lib"; cp -a "$STAGE$P/lib/gjs" "$D$P/lib/"; }
if [ -f "$OUT/GjsPrivate-1.0.typelib" ]; then
  mkdir -p "$D$P/lib/gjs/girepository-1.0"
  cp -a "$OUT/GjsPrivate-1.0.typelib" "$D$P/lib/gjs/girepository-1.0/"
  [ -f "$OUT/GjsPrivate-1.0.gir" ] && cp -a "$OUT/GjsPrivate-1.0.gir" "$D$P/lib/gjs/girepository-1.0/"
else
  echo "WARN: $OUT/GjsPrivate-1.0.typelib not found; generate it on-device and repack gjs for full GI support."
fi
if [ ! "$(find "$D$P/bin" -type f -print -quit 2>/dev/null)" ]; then
  echo "ERROR: no gjs interpreter binary found under $STAGE$P/bin"
  find "$STAGE$P" -maxdepth 4 -type f | sort
  exit 1
fi
mkctrl "$D" gjs Interpreters \
  "libgjs0 (= $V), gir1.2-glib-2.0, gir1.2-freedesktop" \
  "JavaScript interpreter for GNOME"
build_deb gjs

echo "==> package libgjs-dev"
D=$DEBROOT/libgjs-dev
mkdir -p "$D$P/lib" "$D$P/share"
[ -d "$STAGE$P/include" ] && cp -a "$STAGE$P/include" "$D$P/"
[ -d "$STAGE$P/lib/pkgconfig" ] && cp -a "$STAGE$P/lib/pkgconfig" "$D$P/lib/"
find "$STAGE$P/lib" -maxdepth 1 \( -name 'libgjs.dylib' -o -name 'libgjs*.a' \) \
  -exec cp -a {} "$D$P/lib/" \; 2>/dev/null || true
[ -d "$STAGE$P/share/gir-1.0" ] && cp -a "$STAGE$P/share/gir-1.0" "$D$P/share/"
mkctrl "$D" libgjs-dev Development \
  "libgjs0 (= $V), libgirepository-1.0-dev, libmozjs-115-dev, libglib2.0-dev, libcairo2-dev" \
  "JavaScript bindings for GNOME (development files)"
build_deb libgjs-dev

echo "==> built debs"
ls -la "$OUT"/{gjs,libgjs0,libgjs-dev}_${V}_${ARCH}.deb
