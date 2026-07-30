#!/usr/bin/env bash
# Standalone GIMP stack build. This intentionally does not install recipes into
# or invoke the Procursus make system. The container supplies only cctools/SDK
# binaries; the target SDK is assembled from published Xios debs.
set -euo pipefail

WORK="${XIOS_GIMP_WORK:-/work}"
SCRIPTS=/scripts
REPO=/repo-debs
OUT=/out
SRC="$WORK/src"
BUILD="$WORK/build"
SDK="$WORK/sdk"
STAGE="$OUT/gimp-stage"
APPLE_SDK=/root/cctools/SDK/iPhoneOS16.5.sdk
TRIPLE=aarch64-apple-darwin
TOOLS=/root/cctools/bin
CPUS="${XIOS_BUILD_CPUS:-4}"

mkdir -p "$SRC" "$BUILD" "$STAGE"

echo "==> host tools"
apt-get update >/dev/null 2>&1 || true
apt-get install -y --no-install-recommends \
  autoconf automake autopoint appstream gettext gtk-doc-tools intltool \
  gobject-introspection libglib2.0-bin libglib2.0-dev-bin \
  libgdk-pixbuf2.0-bin libgdk-pixbuf-2.0-dev libglib2.0-dev \
  libcairo2-dev librsvg2-dev libtool meson ninja-build patch \
  pkg-config python3 python3-cairo python3-gi gir1.2-gexiv2-0.10 \
  desktop-file-utils libxml2-utils curl xz-utils >/dev/null

echo "==> private Xios SDK"
python3 "$SCRIPTS/extract-sdk.py" --repo "$REPO" --sdk "$SDK" \
  libgtk-3-dev libgdk-pixbuf-2.0-dev libglib2.0-dev libpango1.0-dev \
  libcairo2-dev libfontconfig-dev libfreetype-dev libharfbuzz-dev \
  libjson-glib-dev libjpeg62-turbo-dev libpng16-dev liblcms2-dev \
  libexiv2-dev librsvg2-dev libwebp-dev libappstream-dev \
  libgirepository-1.0-dev libatk1.0-dev libwayland-dev \
  libpoppler-dev libpoppler-glib8 shared-mime-info \
  libxkbcommon-dev libepoxy-dev zlib-dev libgtkintl

PREFIX=/var/jb/usr
TARGET_PREFIX="$SDK$PREFIX"
# The system GTK package supports both backends, but GIMP's private SDK is
# deliberately Wayland-only. This prevents X11-only source paths from being
# selected while retaining the shared package unchanged on-device.
sed -i '/^[[:space:]]*#define GDK_WINDOWING_X11/d' \
  "$TARGET_PREFIX/include/gtk-3.0/gdk/gdkconfig.h"
export PKG_CONFIG_SYSROOT_DIR="$SDK"
export PKG_CONFIG_LIBDIR="$TARGET_PREFIX/lib/pkgconfig:$TARGET_PREFIX/share/pkgconfig"
export PKG_CONFIG_PATH="$PKG_CONFIG_LIBDIR"
export PKG_CONFIG_ALLOW_CROSS=1

export XIOS_GIMP_SDK="$SDK"
export XIOS_GIMP_APPLE_SDK="$APPLE_SDK"
export XIOS_GIMP_CC="$TOOLS/$TRIPLE-clang"
export XIOS_GIMP_CXX="$TOOLS/$TRIPLE-clang++"
export XIOS_GIMP_AR="$TOOLS/$TRIPLE-ar"
export XIOS_GIMP_RANLIB="$TOOLS/$TRIPLE-ranlib"
export XIOS_GIMP_INSTALL_NAME_TOOL="$TOOLS/$TRIPLE-install_name_tool"

COMMON_CFLAGS="-miphoneos-version-min=16.0 -isysroot $APPLE_SDK"
COMMON_LDFLAGS="-miphoneos-version-min=16.0 -isysroot $APPLE_SDK -L$TARGET_PREFIX/lib -Wl,-rpath,$PREFIX/lib"
export CC="$XIOS_GIMP_CC"
export CXX="$XIOS_GIMP_CXX"
export AR="$XIOS_GIMP_AR"
export RANLIB="$XIOS_GIMP_RANLIB"
export STRIP="$TOOLS/$TRIPLE-strip"
export NM="$TOOLS/$TRIPLE-nm"
export CFLAGS="$COMMON_CFLAGS"
export CXXFLAGS="$COMMON_CFLAGS -stdlib=libc++"
export CPPFLAGS="-I$TARGET_PREFIX/include"
export LDFLAGS="$COMMON_LDFLAGS"

CROSS="$WORK/ios-cross.txt"
cat > "$CROSS" <<EOF
[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'

[properties]
needs_exe_wrapper = true
sys_root = '$SDK'

[built-in options]
prefix = '$PREFIX'
c_args = ['-miphoneos-version-min=16.0', '-isysroot', '$APPLE_SDK', '-Wno-error=unused-command-line-argument']
cpp_args = ['-miphoneos-version-min=16.0', '-isysroot', '$APPLE_SDK', '-stdlib=libc++', '-Wno-error=unused-command-line-argument']
c_link_args = ['--ld-path=$TOOLS/$TRIPLE-ld', '-miphoneos-version-min=16.0', '-isysroot', '$APPLE_SDK', '-L$TARGET_PREFIX/lib', '-Wl,-rpath,$PREFIX/lib']
cpp_link_args = ['--ld-path=$TOOLS/$TRIPLE-ld', '-miphoneos-version-min=16.0', '-isysroot', '$APPLE_SDK', '-stdlib=libc++', '-L$TARGET_PREFIX/lib', '-Wl,-rpath,$PREFIX/lib']

[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
pkgconfig = '/usr/bin/pkg-config'
glib-compile-resources = '/usr/bin/glib-compile-resources'
glib-mkenums = '/usr/bin/glib-mkenums'
EOF

HOST_PKG_CONFIG="$WORK/host-pkg-config"
cat > "$HOST_PKG_CONFIG" <<'EOF'
#!/bin/sh
unset PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_LIBDIR PKG_CONFIG_PATH
exec /usr/bin/pkg-config "$@"
EOF
chmod +x "$HOST_PKG_CONFIG"

NATIVE="$WORK/host-native.txt"
cat > "$NATIVE" <<EOF
[binaries]
pkgconfig = '$HOST_PKG_CONFIG'
EOF

# GLib's development metadata references these private base dependencies.
# Their public headers are not used by GIMP, but pkg-config requires metadata
# before it will expose GLib/GObject's own public compile flags.
cat > "$TARGET_PREFIX/lib/pkgconfig/libpcre2-8.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: libpcre2-8
Description: PCRE2 8-bit library supplied by the rootless base
Version: 10.42
Libs: -L\${libdir} -lpcre2-8
Cflags:
EOF
cat > "$TARGET_PREFIX/lib/pkgconfig/libffi.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: libffi
Description: FFI library supplied by the rootless base
Version: 3.4.4
Libs: -L\${libdir} -lffi
Cflags:
EOF
bash /xios-tools/stage-ios-gettext-sdk.sh \
  "$TARGET_PREFIX" "$CC" "$APPLE_SDK" 16.0
# Published development files retain pkg-config references to optional X11
# backends and base libraries that this Wayland-only build does not consume.
# Empty metadata records let pkg-config traverse those private edges without
# adding headers or libraries to the resulting non-static link.
for private_pc in expat xcb-shm xproto pthread-stubs xcb-render xrender \
  kbproto xextproto fixesproto compositeproto damageproto xineramaproto \
  xi xrandr graphite2 fribidi epoll-shim gl; do
  cat > "$TARGET_PREFIX/lib/pkgconfig/$private_pc.pc" <<EOF
prefix=$PREFIX
Name: $private_pc
Description: Unused private dependency in the Xios Wayland SDK
Version: 999
Libs:
Cflags:
EOF
done

cat > "$TARGET_PREFIX/lib/pkgconfig/poppler-data.pc" <<EOF
prefix=$PREFIX
Name: poppler-data
Description: Poppler encoding data supplied by the target runtime
Version: 0.4.12
Libs:
Cflags:
EOF

fetch_extract() {
  local name="$1" url="$2" dirname="$3"
  local archive="$SRC/$(basename "$url")"
  if [ ! -f "$archive" ]; then
    echo "==> download $name"
    curl -fL --retry 3 -o "$archive" "$url"
  fi
  rm -rf "$SRC/$name"
  mkdir -p "$SRC/$name"
  tar -xf "$archive" -C "$SRC/$name" --strip-components=1
  [ -f "$SCRIPTS/../../ports/$name/patches/series" ] || return 0
  while IFS= read -r patch_name; do
    [ -n "$patch_name" ] || continue
    patch -d "$SRC/$name" -p1 < "$SCRIPTS/../../ports/$name/patches/$patch_name"
  done < "$SCRIPTS/../../ports/$name/patches/series"
}

reuse_stage() {
  local name="$1"
  if [ "${XIOS_GIMP_REUSE_STAGES:-1}" = 1 ] \
    && [ -d "$STAGE/$name$PREFIX" ]; then
    echo "==> reuse staged $name"
    cp -a "$STAGE/$name$PREFIX/." "$TARGET_PREFIX/"
    return 0
  fi
  return 1
}

meson_build() {
  local name="$1"; shift
  if reuse_stage "$name"; then
    return 0
  fi
  if [ "$name" = gimp ] && [ -f "$BUILD/$name/build.ninja" ]; then
    echo "==> resume configured $name build"
  else
    rm -rf "$BUILD/$name"
    meson setup "$BUILD/$name" "$SRC/$name" \
      --cross-file "$CROSS" --native-file "$NATIVE" \
      --buildtype=release --wrap-mode=default "$@"
  fi
  ninja -C "$BUILD/$name" -j"$CPUS"
  rm -rf "$STAGE/$name"
  DESTDIR="$STAGE/$name" ninja -C "$BUILD/$name" install
  cp -a "$STAGE/$name$PREFIX/." "$TARGET_PREFIX/"
}

fetch_extract json-c \
  https://s3.amazonaws.com/json-c_releases/releases/json-c-0.18.tar.gz \
  json-c-0.18
if ! reuse_stage json-c; then
  rm -rf "$BUILD/json-c" "$STAGE/json-c"
  cmake -S "$SRC/json-c" -B "$BUILD/json-c" -GNinja \
    -DCMAKE_TOOLCHAIN_FILE="$SCRIPTS/ios-toolchain.cmake" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF \
    -DDISABLE_WERROR=ON -DDISABLE_BSYMBOLIC=ON \
    -DBSYMBOLIC_WORKS=OFF -DVERSION_SCRIPT_WORKS=OFF
  ninja -C "$BUILD/json-c" -j"$CPUS"
  DESTDIR="$STAGE/json-c" cmake --install "$BUILD/json-c"
  cp -a "$STAGE/json-c$PREFIX/." "$TARGET_PREFIX/"
fi

fetch_extract bzip2 \
  https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz \
  bzip2-1.0.8
if ! reuse_stage bzip2; then
  rm -rf "$BUILD/bzip2" "$STAGE/bzip2"
  mkdir -p "$BUILD/bzip2" "$STAGE/bzip2$PREFIX/include" \
    "$STAGE/bzip2$PREFIX/lib/pkgconfig"
  for source_file in blocksort huffman crctable randtable compress decompress bzlib; do
    "$CC" $CFLAGS -fPIC -O2 -c "$SRC/bzip2/$source_file.c" \
      -o "$BUILD/bzip2/$source_file.o"
  done
  "$CC" -dynamiclib $LDFLAGS \
    -Wl,-install_name,$PREFIX/lib/libbz2.1.0.dylib \
    -Wl,-compatibility_version,1.0 -Wl,-current_version,1.0.8 \
    "$BUILD"/bzip2/*.o -o "$STAGE/bzip2$PREFIX/lib/libbz2.1.0.8.dylib"
  ln -s libbz2.1.0.8.dylib "$STAGE/bzip2$PREFIX/lib/libbz2.1.0.dylib"
  ln -s libbz2.1.0.dylib "$STAGE/bzip2$PREFIX/lib/libbz2.dylib"
  cp "$SRC/bzip2/bzlib.h" "$STAGE/bzip2$PREFIX/include/"
  cat > "$STAGE/bzip2$PREFIX/lib/pkgconfig/bzip2.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: bzip2
Description: bzip2 compression library
Version: 1.0.8
Libs: -L\${libdir} -lbz2
Cflags: -I\${includedir}
EOF
  cp -a "$STAGE/bzip2$PREFIX/." "$TARGET_PREFIX/"
fi

fetch_extract xz \
  https://github.com/tukaani-project/xz/releases/download/v5.6.4/xz-5.6.4.tar.xz \
  xz-5.6.4
if ! reuse_stage xz; then
  rm -rf "$BUILD/xz" "$STAGE/xz"
  cmake -S "$SRC/xz" -B "$BUILD/xz" -GNinja \
    -DCMAKE_TOOLCHAIN_FILE="$SCRIPTS/ios-toolchain.cmake" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF -DENABLE_NLS=OFF \
    -DENABLE_X86_ASM=OFF -DCREATE_XZ_SYMLINKS=OFF \
    -DCREATE_LZMA_SYMLINKS=OFF
  ninja -C "$BUILD/xz" -j"$CPUS"
  DESTDIR="$STAGE/xz" cmake --install "$BUILD/xz"
  cp -a "$STAGE/xz$PREFIX/." "$TARGET_PREFIX/"
fi

fetch_extract libtiff \
  https://download.osgeo.org/libtiff/tiff-4.7.0.tar.xz \
  tiff-4.7.0
if ! reuse_stage libtiff; then
  rm -rf "$BUILD/libtiff" "$STAGE/libtiff"
  cmake -S "$SRC/libtiff" -B "$BUILD/libtiff" -GNinja \
    -DCMAKE_TOOLCHAIN_FILE="$SCRIPTS/ios-toolchain.cmake" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DBUILD_SHARED_LIBS=ON -Dtiff-tools=OFF -Dtiff-tests=OFF \
    -Dtiff-contrib=OFF -Dtiff-docs=OFF -Dcxx=OFF \
    -Dld-version-script=OFF -Djpeg=ON -Dzlib=ON \
    -Dlzma=ON -Dwebp=ON -Dzstd=OFF -Dlibdeflate=OFF
  ninja -C "$BUILD/libtiff" -j"$CPUS"
  DESTDIR="$STAGE/libtiff" cmake --install "$BUILD/libtiff"
  cp -a "$STAGE/libtiff$PREFIX/." "$TARGET_PREFIX/"
fi

fetch_extract libarchive \
  https://libarchive.org/downloads/libarchive-3.7.2.tar.xz \
  libarchive-3.7.2
if ! reuse_stage libarchive; then
  rm -rf "$STAGE/libarchive"
  mkdir -p "$STAGE/libarchive$PREFIX/include" \
    "$STAGE/libarchive$PREFIX/lib/pkgconfig"
  cp "$SRC/libarchive/libarchive/archive.h" \
    "$SRC/libarchive/libarchive/archive_entry.h" \
    "$STAGE/libarchive$PREFIX/include/"
  cat > "$STAGE/libarchive$PREFIX/lib/pkgconfig/libarchive.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: libarchive
Description: Multi-format archive and compression library
Version: 3.7.2
Cflags: -I\${includedir}
Libs: -L\${libdir} -larchive
EOF
  cp -a "$STAGE/libarchive$PREFIX/." "$TARGET_PREFIX/"
fi

fetch_extract babl \
  https://download.gimp.org/babl/0.1/babl-0.1.126.tar.xz \
  babl-0.1.126
meson_build babl \
  -Dwith-docs=false -Denable-gir=false -Denable-vapi=false \
  -Dgi-docgen=disabled -Dwith-lcms=enabled \
  -Denable-mmx=false -Denable-sse=false -Denable-sse2=false \
  -Denable-sse4_1=false -Denable-avx2=false -Denable-f16c=false

fetch_extract gexiv2 \
  https://download.gnome.org/sources/gexiv2/0.14/gexiv2-0.14.6.tar.xz \
  gexiv2-0.14.6
meson_build gexiv2 \
  -Dtests=false -Dgtk_doc=false -Dintrospection=false -Dvapi=false \
  -Dtools=true -Dpython3=false

fetch_extract gegl \
  https://download.gimp.org/gegl/0.4/gegl-0.4.70.tar.xz \
  gegl-0.4.70
meson_build gegl \
  -Ddocs=false -Dgtk-doc=false -Dgi-docgen=disabled \
  -Dintrospection=false -Dvapigen=disabled -Dworkshop=false \
  -Dgdk-pixbuf=enabled -Dgexiv2=enabled -Dlcms=enabled \
  -Dlibrsvg=enabled -Dlibtiff=enabled -Dwebp=enabled \
  -Dcairo=enabled -Dpango=enabled -Dpangocairo=enabled \
  -Djasper=disabled -Dlensfun=disabled -Dlibraw=disabled \
  -Dlibv4l=disabled -Dlibv4l2=disabled -Dopenexr=disabled \
  -Dopenmp=disabled -Dpoppler=disabled -Dsdl2=disabled \
  -Dlibav=disabled -Dpygobject=disabled -Dlua=disabled \
  -Dmrg=disabled -Dmaxflow=disabled -Dumfpack=disabled

fetch_extract libmypaint \
  https://github.com/mypaint/libmypaint/releases/download/v1.6.1/libmypaint-1.6.1.tar.xz \
  libmypaint-1.6.1
if ! reuse_stage libmypaint; then
  rm -rf "$BUILD/libmypaint" "$STAGE/libmypaint"
  mkdir -p "$BUILD/libmypaint"
  (
    cd "$SRC/libmypaint"
    # Its legacy Darwin gettext macro makes a fatal dgettext link probe even
    # with NLS disabled. No gettext calls are emitted in this configuration.
    export ac_cv_search_dgettext='none required'
    ./configure --host="$TRIPLE" --prefix="$PREFIX" \
      --disable-static --disable-introspection --disable-openmp \
      --disable-nls --with-glib
    make -j"$CPUS"
    make install DESTDIR="$STAGE/libmypaint"
  )
  cp -a "$STAGE/libmypaint$PREFIX/." "$TARGET_PREFIX/"
fi

fetch_extract mypaint-brushes \
  https://github.com/mypaint/mypaint-brushes/releases/download/v2.0.2/mypaint-brushes-2.0.2.tar.xz \
  mypaint-brushes-2.0.2
if ! reuse_stage mypaint-brushes; then
  rm -rf "$STAGE/mypaint-brushes"
  (
    cd "$SRC/mypaint-brushes"
    ./configure --prefix="$PREFIX"
    make install DESTDIR="$STAGE/mypaint-brushes"
  )
  cp -a "$STAGE/mypaint-brushes$PREFIX/." "$TARGET_PREFIX/"
fi

fetch_extract gimp \
  https://download.gimp.org/gimp/v3.2/gimp-3.2.4.tar.xz \
  gimp-3.2.4
meson_build gimp \
  -Drelocatable-bundle=no -Dcheck-update=no -Dshmem-type=posix \
  -Dlibunwind=false -Dlibbacktrace=false -Dprint=false \
  -Dappdata-test=disabled -Dgi-docgen=disabled -Dheadless-tests=disabled \
  -Dvala=disabled -Djavascript=disabled -Dlua=false \
  -Daa=disabled -Dalsa=disabled -Dfits=disabled -Dghostscript=disabled \
  -Dgudev=disabled -Dheif=disabled -Dilbm=disabled -Djpeg2000=disabled \
  -Djpeg-xl=disabled -Dmng=disabled -Dopenexr=disabled -Dopenmp=disabled \
  -Dwebp=enabled -Dwmf=disabled -Dxcursor=disabled -Dxpm=disabled \
  -Dwebkit-unmaintained=false -Dtwain-unmaintained=false \
  -Dcan-crosscompile-gir=false

echo "==> standalone GIMP stack built"
find "$STAGE" -type f \( -name '*.dylib' -o -perm -111 \) -print | sort
