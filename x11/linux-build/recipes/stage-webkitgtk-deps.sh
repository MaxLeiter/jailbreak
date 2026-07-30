#!/usr/bin/env bash
# Refresh WebKitGTK's dependency surface after Procursus `setup` has populated the base
# sysroot. Running this before setup is too early: setup restores the bootstrap zlib.pc and
# other files over staged rootless metadata.
set -euo pipefail

build_base="${1:?usage: stage-webkitgtk-deps.sh BUILD_BASE}"

echo "==> staging current WebKitGTK dependency debs"
for pkg in \
  libharfbuzz0b libharfbuzz-icu0 libharfbuzz-dev \
  libicu78 libicu-dev \
  libjpeg62-turbo libjpeg62-turbo-dev \
  libepoxy0 libepoxy-dev \
  libxml2 libxml2-dev \
  libpng16-16 libpng16-dev \
  libsqlite3-1 libsqlite3-dev \
  libz1 zlib-dev \
  libwebp7 libwebpdemux2 libwebpmux3 libwebp-dev \
  libatspi2.0-0 at-spi2-core-dev libatk1.0-0 libatk1.0-dev libatk-bridge2.0-0 \
  libgtk-3-0 libgtk-3-dev \
  libfontconfig1 libfontconfig-dev \
  libfreetype6 libfreetype-dev \
  libxslt1.1 libxslt1-dev \
  libsecret-1-0 libsecret-dev \
  libsoup-3.0-0 libsoup-3.0-dev \
  libwayland0 libwayland-dev wayland-protocols; do
  deb="$(find /out /repo-debs -maxdepth 1 -type f -name "${pkg}_*_iphoneos-arm64.deb" \
    -printf '%f\t%p\n' 2>/dev/null | sort -V | tail -1 | cut -f2-)"
  if [ -z "$deb" ]; then
    echo "ERROR: no current $pkg deb in /out or /repo-debs" >&2
    echo "       mount top-level repo/debs read-only at /repo-debs" >&2
    exit 1
  fi
  echo "    staging $deb"
  dpkg-deb -x "$deb" "$build_base"
done

prefix="$build_base/var/jb/usr"
# Procursus' bootstrap expat.pc is still rootful even in this rootless build_base. It is
# pulled transitively by fontconfig's private metadata and otherwise injects the nonexistent
# $build_base/usr/include into WebKit's imported GTK targets during CMake generation.
expat_pc="$prefix/lib/pkgconfig/expat.pc"
if [ -f "$expat_pc" ]; then
  sed -i 's|^prefix=/usr$|prefix=/var/jb/usr|' "$expat_pc"
fi

# XPC sendability compatibility belongs to WebKit's source patch stack. Do not
# rewrite the shared SDK headers here: changing them invalidates the whole engine.
for required in include/gcrypt.h include/libtasn1.h lib/libgcrypt.dylib lib/libtasn1.dylib; do
  if [ ! -e "$prefix/$required" ]; then
    echo "ERROR: warmed GNOME volume is missing $prefix/$required" >&2
    exit 1
  fi
done
