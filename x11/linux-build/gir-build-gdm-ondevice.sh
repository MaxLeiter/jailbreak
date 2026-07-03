#!/bin/bash
set -u
PREFIX=/var/jb/usr; GISPIKE=/var/jb/tmp/gi-spike
export DYLD_LIBRARY_PATH=$PREFIX/lib
export DYLD_INSERT_LIBRARIES=$GISPIKE/sljit_shim.dylib
export CC=$GISPIKE/clang-ios; export CXX=$GISPIKE/clang-ios
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig
export GI_TYPELIB_PATH=$PREFIX/lib/girepository-1.0
export XDG_DATA_DIRS=$PREFIX/share
export PATH=$PREFIX/bin:/var/jb/bin:/usr/bin:/bin
export M4=$PREFIX/bin/m4
NINJA=$GISPIKE/ninja2
[ -e /var/sh ] || ln -sf /var/jb/bin/sh /var/sh

mkdir -p /var/jb/tmp/gir-lib-build && cd /var/jb/tmp/gir-lib-build
rm -rf gdm-client; tar xf /var/jb/tmp/gdm-client.tar; cd gdm-client
grep -rlZ '^#!/bin/sh' . 2>/dev/null | while IFS= read -r -d '' f; do sed -i '1s|^#!/bin/sh|#!/var/jb/bin/sh|' "$f"; done

python3 - libgdm/meson.build <<'PY'
import sys
f=sys.argv[1]; s=open(f).read()
block='''if not meson.is_cross_build()
libgdm_gir = gnome.generate_gir(libgdm,
  sources: [ libgdm_headers, libgdm_sources, libgdm_built_sources ],
  namespace: 'Gdm', nsversion: '1.0', identifier_prefix: 'Gdm',
  includes: libgdm_gir_includes, install: true,
)
endif
'''
marker='# iOS: Gdm-1.0 gir/typelib is generated ON-DEVICE (cross g-ir-scanner cannot run Mach-O).'
if 'generate_gir' not in s:
    s = s.replace(marker, block) if marker in s else s + '\n' + block
    open(f,'w').write(s); print('added generate_gir')
else:
    print('already has generate_gir')
PY

echo "--- meson setup ---"
meson setup _build --prefix=$PREFIX 2>&1 | grep -vE 'Unknown CPU|report this at' | tail -10 || { echo "!! setup failed"; exit 3; }
TL=$($NINJA -C _build -t targets all 2>/dev/null | sed -n 's/:.*//p' | grep -E 'Gdm-1.0.typelib$' || true)
echo "typelib target: $TL"
[ -n "$TL" ] || { echo "!! no Gdm typelib target"; exit 4; }
$NINJA -C _build $TL 2>&1 | grep -vE 'ld: warning|Unknown CPU|report this at' | tail -20
G=$(find _build -name 'Gdm-1.0.gir'); T=$(find _build -name 'Gdm-1.0.typelib')
[ -n "$T" ] || { echo "!! NO Gdm typelib produced"; exit 5; }
cp -v "$G" $PREFIX/share/gir-1.0/; cp -v "$T" $PREFIX/lib/girepository-1.0/
printf "   installed Gdm-1.0.typelib %s bytes\n" "$(stat -c%s "$T" 2>/dev/null || stat -f%z "$T")"
export GI_TYPELIB_PATH=$PREFIX/lib/girepository-1.0:$PREFIX/lib/mutter-14
gjs -c 'const Gdm=imports.gi.Gdm; print("get_session_ids: " + typeof Gdm.get_session_ids);' 2>&1 | tail -2
