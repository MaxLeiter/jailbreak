#!/usr/bin/env bash
# Ladybird rebase (2026-10, upstream b9c913c0) — rebuild ONLY the dependency leaves that are private to
# Ladybird and whose upstream pin moved. Companion to build-ladybird-wave{1,2,3}.sh on the same
# procursus-vol-ladybird volume; it deliberately does NOT touch curl/nghttp2/libxml2/libpng/sqlite/
# freetype/harfbuzz/zlib/libjpeg-turbo/libwebp (system-wide libs owned by the upd-wave-core worker).
#
#   docker run --rm --platform linux/arm64 \
#     -v procursus-vol-ladybird:/work/Procursus \
#     -v "$PWD/build-ladybird-rebase-deps.sh:/work/build-ladybird-rebase-deps.sh:ro" \
#     -v "$PWD/recipes-ladybird:/work/recipes-ladybird:ro" \
#     -v "$PWD/build_info-ladybird:/work/build_info-ladybird:ro" \
#     -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 /work/build-ladybird-rebase-deps.sh
#
# Bumps (to upstream's vcpkg.json pins):
#   openssl 3.5.3 -> 3.6.3   simdutf 7.4.0 -> 9.1.0   simdjson 4.2.4 -> 4.6.4
#   fmt 12.1.0 -> 12.2.0     fast-float 8.1.0 -> 8.2.10
#   mimalloc 2.2.7 (unchanged) now built with MI_SECURE=ON (upstream's mimalloc[secure])
#   ffmpeg 7.1.1 (unchanged) now built as Ladybird-private "-ladybird" libs (new package names)
# Stale-shadow rule (docs: memory x11-ladybird-browser "wipe old copies from build_base before any BUMP"):
# for each bumped package the keyed build_work/build_stage trees and its staged build_base files are removed
# first, otherwise the recipe no-ops on a .build_complete tree and repackages stale binaries.
# Removed paths are echoed ("[removed] ...") so the run log lists exactly what was deleted.
set -uo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
cd /work/Procursus

MINE="openssl simdutf simdjson libfmt fast-float mimalloc ffmpeg"
ONLY="${ONLY:-$MINE}"   # rerun subset, e.g. ONLY="mimalloc ffmpeg"
inonly() { case " $ONLY " in *" $1 "*) return 0;; esac; return 1; }
echo "==> installing recipes (only the Ladybird-private ones) into makefiles/"
for r in $MINE; do cp -v /work/recipes-ladybird/$r.mk makefiles/; done
echo "==> installing control templates into build_info/"
cp -v /work/build_info-ladybird/libsimdutf*.control /work/build_info-ladybird/libsimdjson*.control \
      /work/build_info-ladybird/libfmt12.control /work/build_info-ladybird/fast-float-dev.control \
      /work/build_info-ladybird/libmimalloc*.control \
      /work/build_info-ladybird/libavutil-ladybird*.control /work/build_info-ladybird/libavcodec-ladybird*.control \
      /work/build_info-ladybird/libavformat-ladybird*.control /work/build_info-ladybird/libswresample-ladybird*.control build_info/

cat > build_tools/cc-nounused <<'EOT'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
EOT
cat > build_tools/cxx-nounused <<'EOT'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
EOT
chmod +x build_tools/cc-nounused build_tools/cxx-nounused
COMMON="$XIOS_MEMO_ARGS NO_PGP=1 CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

BW=$XIOS_BUILD_WORK
BS=$XIOS_BUILD_STAGE
BB=$XIOS_SYSROOT
mkdir -p /out
declare -A RESULT

wipe_shadow() {
  local pkg="$1"; shift
  inonly "$pkg" || return 0
  [ "${NO_WIPE:-0}" = 1 ] && { echo "--- NO_WIPE=1: leaving ${pkg} trees in place"; return 0; }
  echo "--- wiping stale ${pkg}: build_work + build_stage + staged build_base files"
  for d in "$BW/${pkg}" "$BS/${pkg}"; do [ -e "$d" ] && echo "[removed] $d"; rm -rf "$d"; done
  for g in "$@"; do
    for f in $BB/$g; do [ -e "$f" ] && echo "[removed] $f"; rm -rf "$f"; done
  done
}
build_one() {
  local pkg="$1"
  inonly "$pkg" || return 0
  echo; echo "###########################################################"; echo "==> make ${pkg}-package"
  echo "###########################################################"
  if make ${pkg}-package $COMMON -j"$(nproc)"; then RESULT[$pkg]="OK"; else RESULT[$pkg]="FAILED"; echo "!!! ${pkg} FAILED"; fi
}

wipe_shadow openssl 'usr/lib/libssl.*' 'usr/lib/libcrypto.*' 'usr/lib/pkgconfig/libssl.pc' 'usr/lib/pkgconfig/libcrypto.pc' 'usr/lib/pkgconfig/openssl.pc' \
  'usr/lib/engines-3' 'usr/lib/ossl-modules' 'usr/include/openssl' 'usr/bin/openssl' 'usr/bin/c_rehash' 'etc/ssl'
build_one openssl
wipe_shadow simdutf 'usr/lib/libsimdutf*' 'usr/include/simdutf*' 'usr/lib/pkgconfig/simdutf.pc' 'usr/lib/cmake/simdutf'
build_one simdutf
wipe_shadow simdjson 'usr/lib/libsimdjson*' 'usr/include/simdjson*' 'usr/lib/pkgconfig/simdjson.pc' 'usr/lib/cmake/simdjson'
build_one simdjson
wipe_shadow libfmt 'usr/lib/libfmt*' 'usr/include/fmt' 'usr/lib/pkgconfig/fmt.pc' 'usr/lib/cmake/fmt'
build_one libfmt
wipe_shadow fast-float 'usr/include/fast_float' 'usr/share/cmake/FastFloat' 'usr/lib/cmake/FastFloat'
build_one fast-float
wipe_shadow mimalloc 'usr/lib/libmimalloc*' 'usr/include/mimalloc*' 'usr/lib/cmake/mimalloc*' 'usr/lib/pkgconfig/libmimalloc.pc'
build_one mimalloc
wipe_shadow ffmpeg 'usr/lib/libav*' 'usr/lib/libsw*' 'usr/lib/pkgconfig/libav*.pc' 'usr/lib/pkgconfig/libsw*.pc' 'usr/include/libav*' 'usr/include/libsw*'
build_one ffmpeg

echo; echo "==> collect debs -> /out (new versions only)"
collect() { find . -name "${1}_${2}_$XIOS_DEB_ARCH.deb" -newermt "-8 hours" -exec cp -v {} /out/ \; 2>/dev/null || true; }
for n in libssl3 libssl-dev libssl-doc openssl;       do collect "$n" '3.6.3+ios1'; done
for n in libsimdutf libsimdutf-dev;                  do collect "$n" '9.1.0+ios1'; done
for n in libsimdjson libsimdjson-dev;                do collect "$n" '4.6.4+ios1'; done
for n in libfmt12 libfmt-dev;                        do collect "$n" '12.2.0+ios1'; done
for n in fast-float-dev;                             do collect "$n" '8.2.10+ios1'; done
for n in libmimalloc libmimalloc-dev;                do collect "$n" '2.2.7+ios2'; done
for n in libavcodec-ladybird61 libavcodec-ladybird-dev libavformat-ladybird61 libavformat-ladybird-dev \
         libavutil-ladybird59 libavutil-ladybird-dev libswresample-ladybird5 libswresample-ladybird-dev; do collect "$n" '7.1.1+ios1'; done

echo; echo "==================== REBASE DEPS SUMMARY ===================="
for p in $MINE; do printf '  %-12s %s\n' "$p" "${RESULT[$p]:-SKIPPED}"; done
echo "--- verification ---"
for f in libssl.3 libcrypto.3 libavutil-ladybird.59 libavcodec-ladybird.61 libavformat-ladybird.61 libswresample-ladybird.5 libmimalloc.2.2; do
  p=$(ls $BB/usr/lib/$f*.dylib 2>/dev/null | head -1); printf '  %-34s %s\n' "$f" "${p:-MISSING}"
done
for pc in openssl libssl libcrypto simdutf simdjson fmt libavcodec-ladybird libavformat-ladybird libavutil-ladybird libswresample-ladybird; do
  v=$(grep -h "^Version:" $BB/usr/lib/pkgconfig/$pc.pc 2>/dev/null | head -1); printf '  %-24s %s\n' "$pc.pc" "${v:-MISSING}"
done
MM=$(ls $BB/usr/lib/libmimalloc.2*.dylib 2>/dev/null | head -1)
[ -n "$MM" ] && echo "  mimalloc LSE mnemonics (must be 0 on A10): $(/root/cctools/bin/aarch64-apple-darwin-otool -tv "$MM" 2>/dev/null | grep -Eiwc 'casal|casa|casl|cas|ldadd|swp|stadd' || true)"
echo "==> done"
