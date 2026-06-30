#!/var/jb/bin/sh
# Package the on-device-built gobject-introspection 1.78 into installable debs.
# Runs ON the iPad. Produces: libgirepository-1.0-1, libgirepository-1.0-dev,
# gobject-introspection, gir1.2-glib-2.0, gir1.2-freedesktop.
set -e
SPIKE=/var/jb/tmp/gi-spike
SRC=$SPIKE/gobject-introspection-1.78.0
BUILD=$SRC/_build
STAGE=$SPIKE/stage          # meson install tree (DESTDIR)
DEBROOT=$SPIKE/debs         # per-package trees + output .debs
V=1.78.0
ARCH=iphoneos-arm64
MAINT="Max Leiter <maxwell.leiter@gmail.com>"
P=/var/jb/usr

rm -rf "$STAGE" "$DEBROOT"; mkdir -p "$STAGE" "$DEBROOT"

echo "=== meson install (--no-rebuild: don't invoke ninja/sh) ==="
cd "$SRC"
export DYLD_LIBRARY_PATH=$P/lib:$BUILD/girepository:$BUILD/girepository/cmph
export DYLD_INSERT_LIBRARIES=$SPIKE/sljit_shim.dylib
DESTDIR="$STAGE" meson install -C _build --no-rebuild

echo "=== add /var/jb/usr/lib rpath to the loader + tools (Procursus parity), re-sign ==="
for f in "$STAGE$P/lib/libgirepository-1.0.1.dylib" \
         "$STAGE$P/bin/g-ir-compiler" "$STAGE$P/bin/g-ir-generate" "$STAGE$P/bin/g-ir-inspect"; do
  [ -f "$f" ] || continue
  install_name_tool -add_rpath $P/lib "$f" 2>/dev/null || true
  ldid -S "$f"
done

# helper: write a DEBIAN/control
mkctrl() { # $1=pkgdir $2=pkgname $3=section $4=depends $5=shortdesc
  mkdir -p "$1/DEBIAN"
  cat > "$1/DEBIAN/control" <<EOF
Package: $2
Version: $V
Architecture: $ARCH
Maintainer: $MAINT
Depends: $4
Section: $3
Homepage: https://gitlab.gnome.org/GNOME/gobject-introspection
Description: $5
 Built on-device (native arm64 g-ir-scanner) for the X11/GNOME-on-iOS stack.
EOF
}

build_deb() { # $1=pkgname  (tree at $DEBROOT/$1)
  ldid -S "$DEBROOT/$1"/$P/lib/*.dylib 2>/dev/null || true
  dpkg-deb -Zxz -b "$DEBROOT/$1" "$DEBROOT/${1}_${V}_${ARCH}.deb"
}

echo "=== libgirepository-1.0-1 (runtime loader) ==="
D=$DEBROOT/libgirepository-1.0-1; mkdir -p "$D$P/lib"
cp -a "$STAGE$P/lib/libgirepository-1.0.1.dylib" "$D$P/lib/"
mkctrl "$D" libgirepository-1.0-1 Libraries "libglib2.0-0, libffi8" \
  "Library for handling GObject introspection data (runtime library)"
build_deb libgirepository-1.0-1

echo "=== gir1.2-glib-2.0 (the foundational typelibs) ==="
D=$DEBROOT/gir1.2-glib-2.0; mkdir -p "$D$P/lib/girepository-1.0"
for t in GLib GObject Gio GModule GIRepository; do
  cp -a "$STAGE$P/lib/girepository-1.0/$t-2.0.typelib" "$D$P/lib/girepository-1.0/"
done
mkctrl "$D" gir1.2-glib-2.0 Introspection \
  "libglib2.0-0, libgirepository-1.0-1 (= $V)" \
  "Introspection data for GLib, GObject, Gio and GModule"
build_deb gir1.2-glib-2.0

echo "=== gir1.2-freedesktop (cairo/freetype/etc typelibs) ==="
D=$DEBROOT/gir1.2-freedesktop; mkdir -p "$D$P/lib/girepository-1.0"
for t in cairo-1.0 freetype2-2.0 fontconfig-2.0 libxml2-2.0 DBus-1.0 DBusGLib-1.0 GL-1.0 Vulkan-1.0 win32-1.0 xfixes-4.0 xft-2.0 xlib-2.0 xrandr-1.3; do
  [ -f "$STAGE$P/lib/girepository-1.0/$t.typelib" ] && \
    cp -a "$STAGE$P/lib/girepository-1.0/$t.typelib" "$D$P/lib/girepository-1.0/" || true
done
mkctrl "$D" gir1.2-freedesktop Introspection \
  "libglib2.0-0, libgirepository-1.0-1 (= $V)" \
  "Introspection data for some FreeDesktop components"
build_deb gir1.2-freedesktop

echo "=== gobject-introspection (the tools + giscanner) ==="
D=$DEBROOT/gobject-introspection; mkdir -p "$D$P/bin" "$D$P/lib" "$D$P/share"
cp -a "$STAGE$P/bin/." "$D$P/bin/"
[ -d "$STAGE$P/lib/gobject-introspection" ] && cp -a "$STAGE$P/lib/gobject-introspection" "$D$P/lib/"
[ -d "$STAGE$P/share/gobject-introspection-1.0" ] && cp -a "$STAGE$P/share/gobject-introspection-1.0" "$D$P/share/"
mkdir -p "$D$P/share/aclocal"; [ -f "$STAGE$P/share/aclocal/introspection.m4" ] && cp -a "$STAGE$P/share/aclocal/introspection.m4" "$D$P/share/aclocal/" || true
ldid -S "$D$P/bin/g-ir-compiler" "$D$P/bin/g-ir-generate" "$D$P/bin/g-ir-inspect" 2>/dev/null || true
ldid -S "$D$P/lib/gobject-introspection/giscanner/"*.so 2>/dev/null || true
mkctrl "$D" gobject-introspection Utilities \
  "python3, libgirepository-1.0-1 (= $V), libglib2.0-dev, clang, pkg-config" \
  "Generate interface introspection data for GObject libraries"
dpkg-deb -Zxz -b "$D" "$DEBROOT/gobject-introspection_${V}_${ARCH}.deb"

echo "=== libgirepository-1.0-dev (headers, .pc, gir XML) ==="
D=$DEBROOT/libgirepository-1.0-dev; mkdir -p "$D$P/lib" "$D$P/include" "$D$P/share"
cp -a "$STAGE$P/lib/libgirepository-1.0.dylib" "$D$P/lib/" 2>/dev/null || true
[ -d "$STAGE$P/lib/pkgconfig" ] && cp -a "$STAGE$P/lib/pkgconfig" "$D$P/lib/"
[ -d "$STAGE$P/include/gobject-introspection-1.0" ] && cp -a "$STAGE$P/include/gobject-introspection-1.0" "$D$P/include/"
[ -d "$STAGE$P/share/gir-1.0" ] && cp -a "$STAGE$P/share/gir-1.0" "$D$P/share/"
mkctrl "$D" libgirepository-1.0-dev Development \
  "libgirepository-1.0-1 (= $V), gir1.2-glib-2.0 (= $V), gobject-introspection (= $V), libffi-dev, libglib2.0-dev" \
  "Library for handling GObject introspection data (development files)"
dpkg-deb -Zxz -b "$D" "$DEBROOT/libgirepository-1.0-dev_${V}_${ARCH}.deb"

echo "=== built debs ==="
ls -la "$DEBROOT"/*.deb
