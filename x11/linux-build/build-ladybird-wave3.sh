#!/usr/bin/env bash
# Build Wave 3 (network + media — the final M0 leaf wave) of the Ladybird-on-iOS dependency
# closure for rootless iphoneos-arm64 via the Procursus/Docker pipeline. Continues
# build-ladybird-wave{1,2}.sh on the same procursus-vol-ladybird volume (zlib/brotli/libpsl/
# freetype/harfbuzz/fontconfig/... already staged there).
#
#   docker run --rm --platform linux/arm64 \
#     -v procursus-vol-ladybird:/work/Procursus \
#     -v "$PWD/build-ladybird-wave3.sh:/work/build-ladybird-wave3.sh:ro" \
#     -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/recipes-ladybird:/work/recipes-ladybird:ro" \
#     -v "$PWD/../ports:/work/ports:ro" \
#     -v "$PWD/build_info-ladybird:/work/build_info-ladybird:ro" \
#     -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 -c /work/build-ladybird-wave3.sh
#
# Wave 3 order (dependency-respecting):
#   openssl 3.5.3 (BUMP)  ->  nghttp2 1.61.0 (REUSE)  ->  curl 8.20.0 (BUMP)  ->  ffmpeg 7.1.1 (NEW)
#   ffmpeg is independent of the network stack (built last for logging convenience).
#
# CRITICAL (stale-shadow wall): this volume was cloned from the gtk track, which staged OLD
# openssl 3.2.1 + curl 8.7.1 into build_base AND left their build_work trees .build_complete.
# Before each BUMP we wipe the KEYED build_work/build_stage trees (else the recipe no-ops and
# repackages stale binaries under the new version) AND the staged build_base lib/headers/.pc shadow
# (else the new build is shadowed at link/stage time — the ICU _icudt74_dat failure mode).
# nghttp2 1.61.0 is the correct pin (curl's http2 dep) and is REUSED as-is — NOT wiped.
set -uo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
cd /work/Procursus

echo "==> installing wave-3 recipes into makefiles/ (bumps/new override upstream)"
cp -v /work/recipes-ladybird/openssl.mk /work/recipes-ladybird/nghttp2.mk \
      /work/recipes-ladybird/curl.mk /work/recipes-ladybird/ffmpeg.mk makefiles/

stage_required_patch_stack() {
  local pkg="$1"
  if [ ! -d "/work/ports/$pkg/patches" ]; then
    echo "ERROR: missing /work/ports/$pkg/patches; mount ports with -v \\$PWD/../ports:/work/ports:ro" >&2
    exit 1
  fi
  echo "==> staging $pkg source patches"
  bash /work/recipes/stage-port-patches.sh "$pkg" /work/ports build_patch
}

stage_required_patch_stack nghttp2
stage_required_patch_stack curl

echo "==> installing wave-3 override control templates into build_info/"
# libcurl4: drop libidn2-0 dep. ffmpeg: new 7.1 soname packages (upstream has 59/57/8 etc.).
cp -v /work/build_info-ladybird/libcurl4.control \
      /work/build_info-ladybird/libavutil59.control \
      /work/build_info-ladybird/libavutil-dev.control \
      /work/build_info-ladybird/libavcodec61.control \
      /work/build_info-ladybird/libavcodec-dev.control \
      /work/build_info-ladybird/libavformat61.control \
      /work/build_info-ladybird/libavformat-dev.control \
      /work/build_info-ladybird/libswresample5.control \
      /work/build_info-ladybird/libswresample-dev.control build_info/

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

BW=$XIOS_BUILD_WORK
BS=$XIOS_BUILD_STAGE
BB=$XIOS_SYSROOT
mkdir -p /out
declare -A RESULT

# Wipe the gtk-era stale source tree (+ .build_complete) AND stage dir so the recipe re-extracts
# and rebuilds the new pinned version, plus the staged build_base shadow so the new version is not
# shadowed at link/stage time. (Reused verbatim from Wave 2.)
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

# 1) openssl 3.5.3 (BUMP from gtk-era 3.2.1). Feeds curl.
wipe_shadow openssl \
  'usr/lib/libssl.*' 'usr/lib/libcrypto.*' 'usr/lib/pkgconfig/libssl.pc' 'usr/lib/pkgconfig/libcrypto.pc' 'usr/lib/pkgconfig/openssl.pc' \
  'usr/lib/engines-3' 'usr/lib/ossl-modules' 'usr/include/openssl' \
  'usr/bin/openssl' 'usr/bin/c_rehash' 'etc/ssl'
build_one openssl

# 2) nghttp2 1.61.0 (REUSE — correct pin, already built+staged; DO NOT wipe). Repackage only.
build_one nghttp2

# 3) curl 8.20.0 (BUMP from gtk-era 8.7.1). Needs openssl(3.5.3)+nghttp2+zlib+brotli+zstd+libpsl.
wipe_shadow curl \
  'usr/lib/libcurl.*' 'usr/lib/pkgconfig/libcurl.pc' 'usr/include/curl' \
  'usr/bin/curl' 'usr/bin/curl-config' 'usr/share/man/man1/curl*' 'usr/share/man/man3/CURL*' 'usr/share/man/man3/curl*'
build_one curl

# 4) ffmpeg 7.1.1 minimal (NEW; independent of the net stack). build_base was clean of libav*.
wipe_shadow ffmpeg \
  'usr/lib/libav*' 'usr/lib/libsw*' 'usr/lib/pkgconfig/libav*.pc' 'usr/lib/pkgconfig/libsw*.pc' \
  'usr/include/libav*' 'usr/include/libsw*'
build_one ffmpeg

echo ""
echo "==> collect debs -> /out (EXACT name_pin_ so gtk-era old versions don't leak)"
collect() { # name  pin
  find . -name "${1}_${2}_iphoneos-arm64.deb" -newermt "-8 hours" -exec cp -v {} /out/ \; 2>/dev/null || true
}
for n in libssl3 libssl-dev libssl-doc openssl;                     do collect "$n" '3.5.3+ios1'; done
for n in libnghttp2-14 libnghttp2-dev;                              do collect "$n" '1.61.0+ios1'; done
for n in curl libcurl4 libcurl4-openssl-dev;                        do collect "$n" '8.20.0+ios1'; done
for n in libavcodec61 libavcodec-dev libavformat61 libavformat-dev \
         libavutil59 libavutil-dev libswresample5 libswresample-dev; do collect "$n" '7.1.1+ios1'; done

echo ""
echo "==================== WAVE 3 SUMMARY ===================="
for p in openssl nghttp2 curl ffmpeg; do
  printf '  %-16s %s\n' "$p" "${RESULT[$p]:-SKIPPED}"
done
echo "========================================================"

echo ""
echo "==> NOUNDEFS / version verification on the emitted dylibs"
verify() {
  local f="$1"
  if [ -f "$f" ]; then
    local u; u=$(nm -m "$f" 2>/dev/null | grep -c "undefined" || true)
    printf '  %-40s arch=%s undef=%s\n' "$(basename $f)" "$(lipo -info "$f" 2>/dev/null | awk '{print $NF}')" "$u"
  else
    printf '  %-40s MISSING\n' "$(basename $f)"
  fi
}
verify $BB/usr/lib/libssl.3.dylib
verify $BB/usr/lib/libcrypto.3.dylib
verify $BB/usr/lib/libnghttp2.14.dylib
verify $BB/usr/lib/libcurl.4.dylib
verify $BB/usr/lib/libavutil.59.dylib
verify $BB/usr/lib/libavcodec.61.dylib
verify $BB/usr/lib/libavformat.61.dylib
verify $BB/usr/lib/libswresample.5.dylib
echo "--- .pc versions ---"
for pc in openssl libcrypto libssl libcurl libnghttp2 libavcodec libavformat libavutil libswresample; do
  v=$(grep -h "^Version:" $BB/usr/lib/pkgconfig/$pc.pc 2>/dev/null | head -1)
  printf '  %-14s %s\n' "$pc" "$v"
done
echo "--- curl feature line (from the built binary) ---"
$BB/usr/bin/curl --version 2>/dev/null | head -3 || echo "  (curl binary not runnable in cross env — expected)"
echo "--- openssl OPENSSL_VERSION_TEXT ---"
grep -h "OPENSSL_VERSION_STR\|OPENSSL_FULL_VERSION_STR\|OPENSSL_VERSION_TEXT" $BB/usr/include/openssl/opensslv.h 2>/dev/null | head -4
echo "==> done"
