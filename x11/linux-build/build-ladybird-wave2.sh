#!/usr/bin/env bash
# Build Wave 2 (font + image stack) of the Ladybird-on-iOS dependency closure for rootless
# iphoneos-arm64 via the Procursus/Docker pipeline. Continues build-ladybird-wave1.sh on the same
# procursus-vol-ladybird volume (zlib/brotli/libtommath/... already staged there).
#
#   docker run --rm --platform linux/arm64 \
#     -v procursus-vol-ladybird:/work/Procursus \
#     -v "$PWD/build-ladybird-wave2.sh:/work/build-ladybird-wave2.sh:ro" \
#     -v "$PWD/recipes-ladybird:/work/recipes-ladybird:ro" \
#     -v "$PWD/build_info-ladybird:/work/build_info-ladybird:ro" \
#     -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 /work/build-ladybird-wave2.sh
#
# Wave 2 order (dependency-respecting):
#   libpng16 (zlib) -> libjpeg-turbo -> libwebp (png+jpeg) -> freetype[no-hb] (zlib+brotli+png)
#   -> harfbuzz (freetype + staged ICU 78.3, meson) -> fontconfig (freetype + system expat + gperf)
#
# CRITICAL (stale-shadow wall): this volume was cloned from the gtk track, which staged OLD
# libpng16/freetype/harfbuzz/fontconfig/libjpeg-turbo into build_base. Before each BUMP we wipe the
# staged shadow (lib+headers+.pc+bin+config) AND the build_work tree so the new version extracts,
# builds, and stages without being shadowed at link time (the ICU _icudt74_dat failure mode).
set -uo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
cd /work/Procursus

echo "==> installing wave-2 recipes into makefiles/ (bumps override upstream)"
cp -v /work/recipes-ladybird/libpng16.mk /work/recipes-ladybird/libjpeg-turbo.mk \
      /work/recipes-ladybird/libwebp.mk /work/recipes-ladybird/freetype.mk \
      /work/recipes-ladybird/harfbuzz.mk /work/recipes-ladybird/fontconfig.mk makefiles/

echo "==> installing wave-2 override control templates into build_info/ (harfbuzz deps, fontconfig no-uuid, libsharpyuv)"
cp -v /work/build_info-ladybird/libharfbuzz0b.control \
      /work/build_info-ladybird/libharfbuzz-icu0.control \
      /work/build_info-ladybird/libharfbuzz-subset0.control \
      /work/build_info-ladybird/libharfbuzz-dev.control \
      /work/build_info-ladybird/libsharpyuv0.control \
      /work/build_info-ladybird/libfontconfig1.control \
      /work/build_info-ladybird/libfontconfig-dev.control \
      /work/build_info-ladybird/libwebp7.control \
      /work/build_info-ladybird/libwebpdemux2.control build_info/

echo "==> (re)installing -Wno-unused-command-line-argument clang wrappers"
cat > build_tools/cc-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
EOF
cat > build_tools/cxx-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
EOF
chmod +x build_tools/cc-nounused build_tools/cxx-nounused

COMMON="$XIOS_MEMO_ARGS NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

# NOTE: Procursus keys build_work/build_stage/build_base by MEMO_TARGET/MEMO_CFVER, so the real
# per-package trees live under .../$XIOS_TRIPLE/<pkg>. Wiping build_work/<pkg>
# (bare) does NOTHING — the stale gtk-era tree + its .build_complete survive and the recipe
# no-op's ("Using previously built"), repackaging stale binaries under the new version. Must wipe
# the keyed paths.
BW=$XIOS_BUILD_WORK
BS=$XIOS_BUILD_STAGE
BB=$XIOS_SYSROOT
mkdir -p /out
declare -A RESULT

# Wipe the gtk-era stale source tree (+ .build_complete) AND stage dir so the recipe re-extracts
# and rebuilds the new pinned version, plus the staged build_base shadow (lib/headers/.pc/bin/
# config) so the new version is not shadowed at link/stage time (the ICU _icudt74_dat failure).
wipe_shadow() {
  local pkg="$1"; shift
  echo "--- wiping stale shadow for ${pkg} (build_work + build_stage + build_base)"
  rm -rf "$BW/${pkg}" "$BS/${pkg}"
  for g in "$@"; do
    rm -rf $BB/$g
  done
}

build_one() {
  local pkg="$1"
  echo ""
  echo "###########################################################"
  echo "==> make ${pkg}-package"
  echo "###########################################################"
  if make ${pkg}-package $COMMON -j"$(nproc)"; then
    RESULT[$pkg]="OK"
  else
    RESULT[$pkg]="FAILED"
    echo "!!! ${pkg} FAILED — continuing with independent packages"
  fi
}

# 1) libpng16 1.6.50 (needs zlib, staged Wave 1)
wipe_shadow libpng16 \
  'usr/lib/libpng16*' 'usr/lib/libpng.*' 'usr/lib/pkgconfig/libpng*.pc' \
  'usr/include/libpng16' 'usr/include/png.h' 'usr/include/pngconf.h' 'usr/include/pnglibconf.h' \
  'usr/bin/libpng16-config' 'usr/bin/png-fix-itxt' 'usr/bin/pngfix' 'usr/share/man/man*/libpng*'
build_one libpng16

# 2) libjpeg-turbo 3.1.1 (independent)
wipe_shadow libjpeg-turbo \
  'usr/lib/libjpeg.*' 'usr/lib/libturbojpeg.*' 'usr/lib/pkgconfig/libjpeg.pc' 'usr/lib/pkgconfig/libturbojpeg.pc' \
  'usr/include/jconfig.h' 'usr/include/jpeglib.h' 'usr/include/jmorecfg.h' 'usr/include/jerror.h' 'usr/include/turbojpeg.h' \
  'usr/bin/cjpeg' 'usr/bin/djpeg' 'usr/bin/jpegtran' 'usr/bin/rdjpgcom' 'usr/bin/wrjpgcom' 'usr/bin/tjbench'
build_one libjpeg-turbo

# 3) libwebp 1.6.0 (needs libpng16 + libjpeg-turbo just staged)
wipe_shadow libwebp \
  'usr/lib/libwebp*' 'usr/lib/libsharpyuv*' 'usr/lib/pkgconfig/libwebp*.pc' 'usr/lib/pkgconfig/libsharpyuv.pc' \
  'usr/lib/cmake/WebP' 'usr/include/webp' \
  'usr/bin/cwebp' 'usr/bin/dwebp' 'usr/bin/webpmux' 'usr/bin/webpinfo' 'usr/bin/img2webp' 'usr/bin/gif2webp' 'usr/bin/vwebp'
build_one libwebp

# 4) freetype 2.13.3 [no harfbuzz] (needs zlib+brotli staged Wave 1, libpng16 just staged)
wipe_shadow freetype \
  'usr/lib/libfreetype.*' 'usr/lib/pkgconfig/freetype2.pc' 'usr/lib/cmake/freetype' \
  'usr/include/freetype2' 'usr/bin/freetype-config' 'usr/share/man/man1/freetype-config*' \
  'usr/share/aclocal/freetype2.m4'
build_one freetype

# 5) harfbuzz 10.2.0 (meson; needs freetype just staged + ICU 78.3 pre-staged)
wipe_shadow harfbuzz \
  'usr/lib/libharfbuzz*' 'usr/lib/pkgconfig/harfbuzz*.pc' 'usr/include/harfbuzz' \
  'usr/lib/cmake/harfbuzz' 'usr/bin/hb-*'
build_one harfbuzz

# 6) fontconfig 2.17.1 (needs freetype just staged + system expat + host gperf)
wipe_shadow fontconfig \
  'usr/lib/libfontconfig.*' 'usr/lib/pkgconfig/fontconfig.pc' 'usr/include/fontconfig' \
  'usr/bin/fc-*' 'usr/share/fontconfig' 'usr/share/xml/fontconfig' 'etc/fonts' \
  'usr/share/man/man3/Fc*' 'usr/share/man/man5/fonts-conf*'
build_one fontconfig

echo ""
echo "==> collect debs -> /out"
for pat in libpng16 libjpeg62-turbo libturbojpeg0 libjpeg-turbo-progs \
           libwebp7 libwebpdemux2 libsharpyuv0 libwebp-dev \
           libfreetype6 libfreetype-dev \
           libharfbuzz0b libharfbuzz-icu0 libharfbuzz-subset0 libharfbuzz-dev \
           fontconfig libfontconfig1 libfontconfig-dev fontconfig-config; do
  find . -name "${pat}_*_$XIOS_DEB_ARCH.deb" -newermt "-8 hours" -exec cp -v {} /out/ \; 2>/dev/null || true
done

echo ""
echo "==================== WAVE 2 SUMMARY ===================="
for p in libpng16 libjpeg-turbo libwebp freetype harfbuzz fontconfig; do
  printf '  %-16s %s\n' "$p" "${RESULT[$p]:-SKIPPED}"
done
echo "========================================================"

echo ""
echo "==> NOUNDEFS / version verification on the emitted dylibs"
verify() {
  local f="$1"; local want="$2"
  if [ -f "$f" ]; then
    local u; u=$(nm -m "$f" 2>/dev/null | grep -c "undefined" || true)
    # arm64 mach-o header + undefined-symbol count (0 = fully resolved / NOUNDEFS-friendly)
    printf '  %-52s arch=%s undef=%s\n' "$(basename $f)" "$(lipo -info "$f" 2>/dev/null | awk '{print $NF}')" "$u"
  else
    printf '  %-52s MISSING\n' "$(basename $f)"
  fi
}
verify $BB/usr/lib/libpng16.16.dylib png
verify $BB/usr/lib/libjpeg.62.dylib jpeg
verify $BB/usr/lib/libwebp.7.dylib webp
verify $BB/usr/lib/libsharpyuv.0.dylib sharpyuv
verify $BB/usr/lib/libfreetype.6.dylib ft
verify $BB/usr/lib/libharfbuzz.0.dylib hb
verify $BB/usr/lib/libharfbuzz-icu.0.dylib hbicu
verify $BB/usr/lib/libfontconfig.1.dylib fc
echo "--- .pc versions ---"
for pc in libpng16 libjpeg freetype2 harfbuzz fontconfig; do
  v=$(grep -h "^Version:" $BB/usr/lib/pkgconfig/$pc.pc 2>/dev/null | head -1)
  printf '  %-14s %s\n' "$pc" "$v"
done
echo "==> done"
