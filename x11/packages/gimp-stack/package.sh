#!/usr/bin/env bash
# Split, sign, and package the standalone GIMP stack built by
# linux-build/build-gimp-stack.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
X11="$(cd "$HERE/../.." && pwd)"
. "$X11/lib/xlib.sh"

OUT="$X11/linux-build/out"
BUILT="$OUT/gimp-stage"
WORK="$OUT/gimp-package-work"
ARCH=iphoneos-arm64

for component in json-c bzip2 xz libtiff libarchive babl gexiv2 gegl \
  libmypaint mypaint-brushes gimp; do
  [ -d "$BUILT/$component/var/jb/usr" ] || {
    echo "missing standalone build stage: $BUILT/$component" >&2
    exit 2
  }
done

rm -rf "$WORK"
mkdir -p "$WORK"

write_control() {
  local stage="$1" package="$2" version="$3" section="$4" depends="$5" description="$6"
  mkdir -p "$stage/DEBIAN"
  {
    echo "Package: $package"
    echo "Version: $version"
    echo "Architecture: $ARCH"
    echo "Maintainer: Max Leiter <max@maxleiter.com>"
    echo "Section: $section"
    echo "Priority: optional"
    echo "Homepage: https://www.gimp.org/"
    [ -z "$depends" ] || echo "Depends: $depends"
    echo "Description: $description"
  } > "$stage/DEBIAN/control"
}

copy_component() {
  local component="$1" stage="$2"
  mkdir -p "$stage"
  cp -a "$BUILT/$component/." "$stage/"
}

remove_devel_files() {
  local stage="$1"
  rm -rf \
    "$stage/var/jb/usr/include" \
    "$stage/var/jb/usr/lib/pkgconfig" \
    "$stage/var/jb/usr/lib/cmake" \
    "$stage/var/jb/usr/share/aclocal" \
    "$stage/var/jb/usr/share/gtk-doc" \
    "$stage/var/jb/usr/share/gir-1.0" \
    "$stage/var/jb/usr/share/vala"
  find "$stage" -type f \( -name '*.a' -o -name '*.la' \) -delete
}

make_dev_stage() {
  local component="$1" stage="$2"
  local root="$BUILT/$component/var/jb/usr"
  mkdir -p "$stage/var/jb/usr"
  [ ! -d "$root/include" ] || cp -a "$root/include" "$stage/var/jb/usr/"
  if [ -d "$root/lib/pkgconfig" ]; then
    mkdir -p "$stage/var/jb/usr/lib"
    cp -a "$root/lib/pkgconfig" "$stage/var/jb/usr/lib/"
  fi
  if [ -d "$root/lib/cmake" ]; then
    mkdir -p "$stage/var/jb/usr/lib"
    cp -a "$root/lib/cmake" "$stage/var/jb/usr/lib/"
  fi
}

sign_stage() {
  local stage="$1"
  while IFS= read -r file_path; do
    if file "$file_path" | grep -q 'Mach-O'; then
      xsign "$file_path"
    fi
  done < <(find "$stage" -type f)
}

retarget_import() {
  local stage="$1" old="$2" new="$3"
  local file_path
  while IFS= read -r file_path; do
    file "$file_path" | grep -q 'Mach-O' || continue
    otool -L "$file_path" 2>/dev/null | grep -Fq "$old" || continue
    install_name_tool -change "$old" "$new" "$file_path"
  done < <(find "$stage" -type f)
}

normalize_rootless_rpath() {
  local stage="$1" file_path
  while IFS= read -r file_path; do
    file "$file_path" | grep -q 'Mach-O' || continue
    if otool -l "$file_path" 2>/dev/null \
      | awk '/LC_RPATH/{getline; getline; print $2}' \
      | grep -Fxq "/work/sdk/var/jb/usr/lib"; then
      install_name_tool -delete_rpath \
        "/work/sdk/var/jb/usr/lib" "$file_path"
    fi
    if ! otool -l "$file_path" 2>/dev/null \
      | awk '/LC_RPATH/{getline; getline; print $2}' \
      | grep -Fxq "/var/jb/usr/lib"; then
      install_name_tool -add_rpath "/var/jb/usr/lib" "$file_path"
    fi
  done < <(find "$stage" -type f)
}

pack_runtime_and_dev() {
  local component="$1" runtime_pkg="$2" dev_pkg="$3" version="$4"
  local runtime_deps="$5" summary="$6"
  local runtime="$WORK/$runtime_pkg" dev="$WORK/$dev_pkg"
  copy_component "$component" "$runtime"
  remove_devel_files "$runtime"
  make_dev_stage "$component" "$dev"
  write_control "$runtime" "$runtime_pkg" "$version" Libraries "$runtime_deps" "$summary"
  write_control "$dev" "$dev_pkg" "$version" Development \
    "$runtime_pkg (= $version)" "development files for $summary"
  sign_stage "$runtime"
  xmkdeb "$runtime" "$OUT" --minos >/dev/null
  xmkdeb "$dev" "$OUT" --minos >/dev/null
}

pack_runtime_and_dev json-c libjson-c5 libjson-c-dev 0.18+ios1 \
  "" "JSON-C runtime for Xios desktop applications"

pack_runtime_and_dev bzip2 libbz2-1.0 libbz2-dev 1.0.8+ios1 \
  "" "bzip2 compression runtime for GIMP"

# Procursus also owns liblzma5/liblzma-dev. Keep our newer, directly built XZ
# runtime private to the new libtiff6 ABI instead of shadowing a base package.
TIFF="$WORK/libtiff6"
copy_component libtiff "$TIFF"
remove_devel_files "$TIFF"
rm -f "$TIFF/var/jb/usr/lib/libtiff.dylib" \
  "$TIFF/var/jb/usr/lib/libtiffxx.dylib"
mkdir -p "$TIFF/var/jb/usr/lib/gimp-private"
cp "$BUILT/xz/var/jb/usr/lib/liblzma.5.6.4.dylib" \
  "$TIFF/var/jb/usr/lib/gimp-private/liblzma.5.dylib"
install_name_tool -id \
  "/var/jb/usr/lib/gimp-private/liblzma.5.dylib" \
  "$TIFF/var/jb/usr/lib/gimp-private/liblzma.5.dylib"
retarget_import "$TIFF" \
  "@rpath/liblzma.5.dylib" \
  "/var/jb/usr/lib/gimp-private/liblzma.5.dylib"
retarget_import "$TIFF" \
  "/var/jb/usr/lib/liblzma.5.dylib" \
  "/var/jb/usr/lib/gimp-private/liblzma.5.dylib"
write_control "$TIFF" libtiff6 4.7.0+ios2 Libraries \
  "libjpeg62-turbo, libwebp7, libz1" \
  "TIFF image codec runtime for GIMP with a private XZ runtime"
sign_stage "$TIFF"
xmkdeb "$TIFF" "$OUT" --minos >/dev/null

pack_runtime_and_dev babl libbabl-0.1-0 libbabl-0.1-dev 0.1.126+ios1 \
  "liblcms2-2" "babl pixel-format conversion runtime"

pack_runtime_and_dev gexiv2 libgexiv2-2 libgexiv2-dev 0.14.6+ios1 \
  "libglib2.0-0, libexiv2-28" "GObject metadata bindings for Exiv2"

GEGL_RUNTIME="$WORK/libgegl-0.4-0"
GEGL_DEV="$WORK/libgegl-dev"
GEGL_CLI="$WORK/gegl"
copy_component gegl "$GEGL_RUNTIME"
remove_devel_files "$GEGL_RUNTIME"
make_dev_stage gegl "$GEGL_DEV"
mkdir -p "$GEGL_CLI/var/jb/usr"
if [ -d "$GEGL_RUNTIME/var/jb/usr/bin" ]; then
  mv "$GEGL_RUNTIME/var/jb/usr/bin" "$GEGL_CLI/var/jb/usr/"
fi
write_control "$GEGL_RUNTIME" libgegl-0.4-0 0.4.70+ios2 Libraries \
  "libbabl-0.1-0, libglib2.0-0, libjson-glib-1.0-0, libjpeg62-turbo, libpng16-16, libgexiv2-2, liblcms2-2, librsvg2-2, libwebp7" \
  "GEGL image-processing runtime and operations"
write_control "$GEGL_DEV" libgegl-dev 0.4.70+ios2 Development \
  "libgegl-0.4-0 (= 0.4.70+ios2)" \
  "development files for GEGL image processing"
write_control "$GEGL_CLI" gegl 0.4.70+ios2 Graphics \
  "libgegl-0.4-0 (= 0.4.70+ios2)" "GEGL command-line image processing tools"
echo "Replaces: libgegl-0.4-0 (<< 0.4.70+ios2)" \
  >> "$GEGL_CLI/DEBIAN/control"
sign_stage "$GEGL_RUNTIME"
sign_stage "$GEGL_CLI"
xmkdeb "$GEGL_RUNTIME" "$OUT" --minos >/dev/null
xmkdeb "$GEGL_DEV" "$OUT" --minos >/dev/null
xmkdeb "$GEGL_CLI" "$OUT" --minos >/dev/null

pack_runtime_and_dev libmypaint libmypaint-1.5-1 libmypaint-dev 1.6.1+ios1 \
  "libjson-c5, libglib2.0-0" "MyPaint brush engine used by GIMP"

BRUSHES="$WORK/mypaint-brushes"
copy_component mypaint-brushes "$BRUSHES"
write_control "$BRUSHES" mypaint-brushes 2.0.2+ios1 Graphics \
  "" "MyPaint 2 brush collection used by GIMP"
xmkdeb "$BRUSHES" "$OUT" --minos >/dev/null

GIMP="$WORK/gimp"
copy_component gimp "$GIMP"
remove_devel_files "$GIMP"
# Apple's SDK also exposes a system libarchive. A bare -larchive therefore
# records /usr/lib/libarchive.2.dylib during the cross-link, while our rootless
# runtime is the ABI-matched libarchive13 package under /var/jb. Retarget before
# signing so the executable and file-compressor plug-in resolve that package.
retarget_import "$GIMP" \
  "/usr/lib/libarchive.2.dylib" "@rpath/libarchive.13.dylib"
# Host Python is used for GIMP's build generators. Target Python plug-ins are a
# separate follow-up; do not ship scripts that cannot run in this first package.
rm -rf "$GIMP/var/jb/usr/lib/gimp/3.0/plug-ins/python" \
  "$GIMP/var/jb/usr/share/gimp/3.0/plug-ins/python"
find "$GIMP/var/jb/usr/lib/gimp/3.0" \
     "$GIMP/var/jb/usr/share/gimp/3.0" \
  -type f -name '*.py' -delete 2>/dev/null || true
# The bundled goat extension and test-sphere plug-in are developer examples,
# not end-user features. Their metadata/shebangs still advertise interpreters
# omitted from this target package, so omit the complete examples rather than
# leaving broken entries in GIMP's extension and plug-in browsers.
rm -rf \
  "$GIMP/var/jb/usr/lib/gimp/3.0/extensions/org.gimp.extension.goat-exercises" \
  "$GIMP/var/jb/usr/lib/gimp/3.0/plug-ins/test-sphere-v3"
normalize_rootless_rpath "$GIMP"
write_control "$GIMP" gimp 3.2.4+ios3 Graphics \
  "libbabl-0.1-0, libgegl-0.4-0, gegl, libgexiv2-2, libmypaint-1.5-1, mypaint-brushes, libbz2-1.0, libtiff6, libgtk-3-0, libgdk-pixbuf-2.0-0, libglib2.0-0, libpango-1.0-0, libcairo2, libfontconfig1, libfreetype6, libharfbuzz0b, libjson-glib-1.0-0, libjpeg62-turbo, libpng16-16, liblcms2-2, libexiv2-28, librsvg2-2, libwebp7, libappstream5, libarchive13, libgtkintl, libpoppler-glib8, libpoppler140, shared-mime-info" \
  "GIMP 3.2 image editor for Xios Wayland desktops"
sign_stage "$GIMP"
xmkdeb "$GIMP" "$OUT" --minos >/dev/null

DESKTOP="$(find "$GIMP/var/jb/usr/share/applications" -type f -name '*.desktop' | head -1)"
[ -n "$DESKTOP" ] || { echo "GIMP package has no desktop entry" >&2; exit 2; }

# Never package a cached native host: its ioscd launch protocol and native-frame
# protocol must match the source currently being shipped. A stale IOSCHost here
# previously kept the UIKit scene alive while ioscd rejected its obsolete
# app-id-plus-executable request, leaving a black launch window.
bash "$X11/apps/iosc-host/build-host.sh"

NATIVE_BUNDLES="$WORK/native-bundles"
bash "$X11/apps/iosc-desktop/gen-launchers.sh" \
  --native \
  --icons-root "$GIMP/var/jb/usr/share" \
  --out "$NATIVE_BUNDLES" \
  "$DESKTOP"
GENERATED_APP="$(find "$NATIVE_BUNDLES" -maxdepth 1 -type d -name '*.app' | head -1)"
[ -n "$GENERATED_APP" ] || { echo "native GIMP bundle was not generated" >&2; exit 2; }

# GIMP's upstream desktop entry expands the acronym. Keep that descriptive name
# in the desktop package, but use the familiar short product name on SpringBoard
# and inside the native scene. IOSCExec belonged to the retired launch protocol;
# remove it defensively even when packaging against an older generated bundle.
NATIVE_PLIST="$GENERATED_APP/Info.plist"
PB=/usr/libexec/PlistBuddy
"$PB" -c "Set :CFBundleName GIMP" "$NATIVE_PLIST"
"$PB" -c "Set :CFBundleDisplayName GIMP" "$NATIVE_PLIST"
"$PB" -c "Set :IOSCName GIMP" "$NATIVE_PLIST"
"$PB" -c "Set :CFBundleShortVersionString 3.2.4" "$NATIVE_PLIST"
"$PB" -c "Set :CFBundleVersion 5" "$NATIVE_PLIST"
"$PB" -c "Delete :IOSCExec" "$NATIVE_PLIST" >/dev/null 2>&1 || true

GIMP_NATIVE="$WORK/gimp-native"
mkdir -p "$GIMP_NATIVE/var/jb/Applications"
cp -a "$GENERATED_APP" "$GIMP_NATIVE/var/jb/Applications/GIMP.app"
write_control "$GIMP_NATIVE" gimp-native 3.2.4+ios5 Applications \
  "gimp (= 3.2.4+ios3), xios-launcher-tools (>= 0.1.3), iosc (>= 0.9.38)" \
  "native iPadOS multi-window host app for GIMP"
cat > "$GIMP_NATIVE/DEBIAN/postinst" <<'POSTINST'
#!/var/jb/bin/sh
chmod 0755 /var/jb/Applications/GIMP.app/IOSCHost 2>/dev/null || true
/var/jb/usr/bin/uicache -p /var/jb/Applications/GIMP.app >/dev/null 2>&1 || true
exit 0
POSTINST
cat > "$GIMP_NATIVE/DEBIAN/postrm" <<'POSTRM'
#!/var/jb/bin/sh
/var/jb/usr/bin/uicache -u /var/jb/Applications/GIMP.app >/dev/null 2>&1 || true
exit 0
POSTRM
chmod 0755 "$GIMP_NATIVE/DEBIAN/postinst" "$GIMP_NATIVE/DEBIAN/postrm"
sign_stage "$GIMP_NATIVE"
# The generic sweep above is appropriate for ordinary Mach-O payloads, but an
# IOSCHost must retain its narrow GPU/IOSurface, Metal-event-broker, and native
# socket filesystem entitlements. Reapply and verify those markers last.
xsign "$GIMP_NATIVE/var/jb/Applications/GIMP.app/IOSCHost" \
  "$X11/apps/iosc-host/entitlements.plist" \
  AGXDeviceUserClient IOGPUDeviceUserClient IOSurfaceRootUserClient \
  com.max.xios.metal-event-broker \
  com.apple.security.exception.files.absolute-path.read-write
xmkdeb "$GIMP_NATIVE" "$OUT" --minos >/dev/null

echo "==> standalone GIMP packages"
find "$OUT" -maxdepth 1 -type f \
  \( -name 'libjson-c*.deb' -o -name 'libbz2*.deb' \
     -o -name 'libtiff6_*.deb' \
     -o -name 'libbabl*.deb' -o -name 'libgexiv2*.deb' \
     -o -name 'libgegl*.deb' -o -name 'gegl_*.deb' -o -name 'libmypaint*.deb' \
     -o -name 'mypaint-brushes*.deb' -o -name 'gimp_*.deb' \
     -o -name 'gimp-native*.deb' \) -print | sort
