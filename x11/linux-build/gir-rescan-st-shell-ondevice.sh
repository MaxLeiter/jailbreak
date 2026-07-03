#!/bin/bash
# Force-regenerate St-14 + Shell-14 typelibs against the now-real Atk/Atspi/Gcr/Gck typelibs.
# The Jul-1 scan ran against STUB Atk, so g-ir-scanner dropped every St/Shell method with an
# Atk.* parameter (e.g. st_widget_add/remove_accessible_state) as non-introspectable.
set -u
PREFIX=/var/jb/usr
GISPIKE=/var/jb/tmp/gi-spike
TREE=/var/jb/tmp/gnome-shell-gir/gnome-shell-46.0
export DYLD_LIBRARY_PATH=$PREFIX/lib:$PREFIX/lib/gnome-shell:$PREFIX/lib/mutter-14:/var/jb/lib/angle
export DYLD_INSERT_LIBRARIES=$GISPIKE/sljit_shim.dylib
export CC=$GISPIKE/clang-ios
export CXX=$GISPIKE/clang-ios
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig
export GI_TYPELIB_PATH=$PREFIX/lib/girepository-1.0:$PREFIX/lib/mutter-14
export XDG_DATA_DIRS=$PREFIX/share
export PATH=$PREFIX/bin:/var/jb/bin:/usr/bin:/bin
export M4=$PREFIX/bin/m4
NINJA=$GISPIKE/ninja2
[ -e /var/sh ] || ln -sf /var/jb/bin/sh /var/sh

cd "$TREE/_build" || { echo "!! no tree"; exit 2; }
echo "--- forcing St-14 + Shell-14 regeneration (removing stale gir/typelib outputs) ---"
rm -f src/st/St-14.gir src/st/St-14.typelib src/Shell-14.gir src/Shell-14.typelib
$NINJA src/st/St-14.typelib src/Shell-14.typelib 2>&1 \
  | grep -vE "ld: warning|Unknown CPU family|report this at" | tail -30

echo "--- install regenerated gir + typelib ---"
for f in src/st/St-14 src/Shell-14; do
  [ -f "$f.typelib" ] || { echo "!! $f.typelib NOT produced"; exit 3; }
  cp -v "$f.gir" $PREFIX/share/gir-1.0/
  cp -v "$f.typelib" $PREFIX/lib/girepository-1.0/
  b=$(basename "$f"); printf "   installed %-16s %s bytes\n" "$b.typelib" "$(stat -c%s "$f.typelib" 2>/dev/null || stat -f%z "$f.typelib")"
done
echo "--- verify St.Widget now has add/remove_accessible_state ---"
export GI_TYPELIB_PATH=$PREFIX/lib/girepository-1.0:$PREFIX/lib/mutter-14
gjs -c 'imports.gi.versions.St="14"; const St=imports.gi.St;
  print("add_accessible_state: " + typeof St.Widget.prototype.add_accessible_state);
  print("remove_accessible_state: " + typeof St.Widget.prototype.remove_accessible_state);' 2>&1 | tail -5
