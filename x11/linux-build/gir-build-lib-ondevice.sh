#!/bin/bash
# gir-build-lib.sh <base-dir> [extra meson args...] — build ONE library's introspection
# (.gir + .typelib) natively on the iPad and install it, using the gi-spike toolchain.
# The library's OWN meson build drives g-ir-scanner over its sources, which is the route that
# correctly handles umbrella-header include guards (unlike a standalone header scan).
set -u
BASE="${1:?usage: gir-build-lib.sh <base-dir> [meson args...]}"; shift || true
PREFIX=/var/jb/usr
GISPIKE=/var/jb/tmp/gi-spike
WORK=/var/jb/tmp/gir-lib-build
export DYLD_LIBRARY_PATH=$PREFIX/lib
export DYLD_INSERT_LIBRARIES=$GISPIKE/sljit_shim.dylib
export CC=$GISPIKE/clang-ios
export CXX=$GISPIKE/clang-ios
export PKG_CONFIG_PATH=$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig
export GI_TYPELIB_PATH=$PREFIX/lib/girepository-1.0
export XDG_DATA_DIRS=$PREFIX/share
export PATH=$PREFIX/bin:/var/jb/bin:/usr/bin:/bin
export M4=$PREFIX/bin/m4
NINJA=$GISPIKE/ninja2
[ -e /var/sh ] || ln -sf /var/jb/bin/sh /var/sh

mkdir -p "$WORK" && cd "$WORK"
[ -f "/var/jb/tmp/$BASE.tar" ] || { echo "!! /var/jb/tmp/$BASE.tar not found"; exit 2; }
rm -rf "$BASE"
tar xf "/var/jb/tmp/$BASE.tar"
cd "$BASE"

# This rootless device has NO /bin/sh (only /var/jb/bin/sh). Build-time codegen scripts
# shipped with #!/bin/sh shebangs (e.g. gcr's gcr-mkoids) fail with "/bin/sh: not found".
# Rewrite those shebangs to the real sh. Harmless for libs that have none.
grep -rlZ --include='*' '^#!/bin/sh' . 2>/dev/null | while IFS= read -r -d '' f; do
  sed -i '1s|^#!/bin/sh|#!/var/jb/bin/sh|' "$f" 2>/dev/null && echo "   shebang-fixed: $f"
done

# optional per-lib source patch before configure (e.g. drop a build-only python-gi requirement)
[ -n "${PRE_SETUP:-}" ] && { echo "--- PRE_SETUP: $PRE_SETUP ---"; eval "$PRE_SETUP"; }

echo "--- meson setup ($BASE): introspection on ---"
# introspection flag is passed by the caller ("$@") since libs disagree on the option type
# (atk/polkit: boolean true; at-spi2-core/gcr: feature enabled).
meson setup _build --prefix=$PREFIX "$@" 2>&1 | tail -12 || {
  echo "!! meson setup failed"; exit 3; }

echo "--- ninja: typelib targets only ---"
if [ -n "${ONLY_TL:-}" ]; then
  TL="$ONLY_TL"   # caller restricts to specific typelib target(s) (e.g. skip a broken bundled one)
else
  TL=$($NINJA -C _build -t targets all 2>/dev/null | sed -n 's/:.*//p' | grep -E '\.typelib$' || true)
fi
echo "typelib targets: $TL"
[ -n "$TL" ] || { echo "!! no typelib targets found (introspection off?)"; exit 4; }
$NINJA -C _build $TL 2>&1 | tail -25

echo "--- install produced gir + typelib ---"
GIRS=$(find _build -name '*.gir'); TLS=$(find _build -name '*.typelib')
[ -n "$TLS" ] || { echo "!! NO TYPELIB PRODUCED"; exit 5; }
mkdir -p $PREFIX/share/gir-1.0 $PREFIX/lib/girepository-1.0
for g in $GIRS; do cp -v "$g" $PREFIX/share/gir-1.0/; done
for t in $TLS;  do
  cp -v "$t" $PREFIX/lib/girepository-1.0/
  b=$(basename "$t"); printf "   installed %-22s %s bytes\n" "$b" "$(stat -c%s "$t" 2>/dev/null || stat -f%z "$t")"
done
echo "--- DONE $BASE ---"
