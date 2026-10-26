#!/usr/bin/env bash
# ABI-stable security/bugfix rebuild of core shared libs that shadow Procursus packages, on the
# procursus-vol-ladybird volume with the recipes-ladybird tree. One target at a time, so a
# curl/nghttp2 bump does not drag openssl or ffmpeg 7.1 along (build-ladybird-wave3.sh rebuilds both).
#
#   docker run --rm --platform linux/arm64 -e TARGETS="libxml2 nghttp2 curl" \
#     -v procursus-vol-ladybird:/work/Procursus \
#     -v "$PWD/build-upd-core-ladybird.sh:/work/build-upd-core-ladybird.sh:ro" \
#     -v "$PWD/recipes:/work/recipes:ro" -v "$PWD/recipes-ladybird:/work/recipes-ladybird:ro" \
#     -v "$PWD/../ports:/work/ports:ro" -v "$PWD/build_info-ladybird:/work/build_info-ladybird:ro" \
#     -v "$PWD/out:/out" procursus-xbuild:bookworm-arm64 /work/build-upd-core-ladybird.sh
#
# TARGETS (default none): libxml2 nghttp2 curl libpng16 freetype sqlite3 harfbuzz. Order is fixed below.
# Every target wipes its keyed build_work/build_stage trees and the staged build_base shadow first,
# because the recipes no-op on an existing .build_complete (same stale-shadow wall as waves 2/3).
set -uo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
cd /work/Procursus
TARGETS="${TARGETS:-}"
want() { [[ " $TARGETS " == *" $1 "* ]]; }

stage_patch_stack() {
  [ -d "/work/ports/$1/patches" ] || { echo "ERROR: missing /work/ports/$1/patches" >&2; exit 1; }
  bash /work/recipes/stage-port-patches.sh "$1" /work/ports build_patch
}

cp -v /work/recipes-ladybird/{libxml2,nghttp2,curl,libpng16,freetype,sqlite3,harfbuzz}.mk makefiles/
cp -v /work/build_info-ladybird/libcurl4.control \
      /work/build_info-ladybird/libharfbuzz0b.control /work/build_info-ladybird/libharfbuzz-icu0.control \
      /work/build_info-ladybird/libharfbuzz-subset0.control /work/build_info-ladybird/libharfbuzz-dev.control build_info/
want nghttp2 && stage_patch_stack nghttp2
want curl && stage_patch_stack curl
want harfbuzz && stage_patch_stack harfbuzz
if want harfbuzz && ! command -v glib-mkenums >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq libglib2.0-dev-bin >/dev/null || echo "!!! no glib-mkenums"
fi

cat > build_tools/cc-nounused <<'X'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
X
cat > build_tools/cxx-nounused <<'X'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
X
chmod +x build_tools/cc-nounused build_tools/cxx-nounused
COMMON="$XIOS_MEMO_ARGS NO_PGP=1 CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"
BW=$XIOS_BUILD_WORK; BS=$XIOS_BUILD_STAGE; BB=$XIOS_SYSROOT
mkdir -p /out
declare -A RESULT
START=$(date +%s)

run() { # pkg, shadow globs...
  local pkg="$1"; shift
  want "$pkg" || return 0
  echo; echo "########## $pkg ##########"
  rm -rf "$BW/$pkg" "$BS/$pkg"
  for g in "$@"; do rm -rf $BB/$g; done
  if make ${pkg}-package $COMMON -j"$(nproc)"; then RESULT[$pkg]=OK; else RESULT[$pkg]=FAILED; fi
}

run libxml2 'usr/lib/libxml2.*' 'usr/lib/pkgconfig/libxml-2.0.pc' 'usr/include/libxml2' 'usr/lib/cmake/libxml2' \
  'usr/bin/xmllint' 'usr/bin/xmlcatalog' 'usr/bin/xml2-config'
run nghttp2 'usr/lib/libnghttp2.*' 'usr/lib/pkgconfig/libnghttp2.pc' 'usr/include/nghttp2'
run curl 'usr/lib/libcurl.*' 'usr/lib/pkgconfig/libcurl.pc' 'usr/include/curl' 'usr/bin/curl' 'usr/bin/curl-config' \
  'usr/share/man/man1/curl*' 'usr/share/man/man3/CURL*' 'usr/share/man/man3/curl*'
run libpng16 'usr/lib/libpng16*' 'usr/lib/libpng.*' 'usr/lib/pkgconfig/libpng*.pc' 'usr/include/libpng16' \
  'usr/include/png.h' 'usr/include/pngconf.h' 'usr/include/pnglibconf.h' 'usr/bin/libpng16-config' \
  'usr/bin/png-fix-itxt' 'usr/bin/pngfix' 'usr/share/man/man*/libpng*'
run freetype 'usr/lib/libfreetype.*' 'usr/lib/pkgconfig/freetype2.pc' 'usr/lib/cmake/freetype' 'usr/include/freetype2' \
  'usr/bin/freetype-config' 'usr/share/man/man1/freetype-config*' 'usr/share/aclocal/freetype2.m4'
run sqlite3 'usr/lib/libsqlite3.*' 'usr/lib/pkgconfig/sqlite3.pc' 'usr/include/sqlite3*.h' 'usr/bin/sqlite3'
run harfbuzz 'usr/lib/libharfbuzz*' 'usr/lib/pkgconfig/harfbuzz*.pc' 'usr/include/harfbuzz' 'usr/lib/cmake/harfbuzz' 'usr/bin/hb-*'

echo; echo "==> collect debs (this run only) -> /out"
for pat in libxml2 libxml2-dev libxml2-utils libnghttp2-14 libnghttp2-dev curl libcurl4 libcurl4-openssl-dev \
           libpng16-16 libpng16-dev libpng16-tools libfreetype6 libfreetype-dev sqlite3 libsqlite3-1 libsqlite3-dev \
           libharfbuzz0b libharfbuzz-icu0 libharfbuzz-subset0 libharfbuzz-gobject0 libharfbuzz-bin libharfbuzz-dev; do
  find . -name "${pat}_*_$XIOS_DEB_ARCH.deb" -newermt "@$START" -exec cp -v {} /out/ \; 2>/dev/null || true
done
echo "==================== SUMMARY ===================="
for p in libxml2 nghttp2 curl libpng16 freetype sqlite3 harfbuzz; do want $p && printf '  %-10s %s\n' $p "${RESULT[$p]:-SKIPPED}"; done
for f in $BB/usr/lib/libxml2.2.dylib $BB/usr/lib/libnghttp2.14.dylib $BB/usr/lib/libcurl.4.dylib \
         $BB/usr/lib/libpng16.16.dylib $BB/usr/lib/libfreetype.6.dylib $BB/usr/lib/libsqlite3.1.dylib $BB/usr/lib/libharfbuzz.0.dylib; do
  [ -e "$f" ] && echo "  staged: $(basename $f)"
done
for p in "${!RESULT[@]}"; do [ "${RESULT[$p]}" = OK ] || exit 1; done
