#!/usr/bin/env bash
# Build Wave 1 (foundation / low-risk leaves) of the Ladybird-on-iOS dependency closure for
# rootless iphoneos-arm64 via the Procursus/Docker pipeline. Companion to build-icu.sh — same
# preamble (recipes + build_info install + cc-nounused wrappers), run on procursus-vol-ladybird.
#
#   docker run --rm --platform linux/arm64 \
#     -v procursus-vol-ladybird:/work/Procursus \
#     -v "$PWD/build-ladybird-wave1.sh:/work/build-ladybird-wave1.sh:ro" \
#     -v "$PWD/recipes-ladybird:/work/recipes-ladybird:ro" \
#     -v "$PWD/build_info-ladybird:/work/build_info-ladybird:ro" \
#     -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 /work/build-ladybird-wave1.sh
#
# Wave 1 = zlib brotli libtommath fmt sqlite3 simdutf simdjson fast-float mimalloc wuffs
#          (Tier 0) then libxml2 (needs zlib) woff2 (needs brotli) (Tier 1).
# expat is a system lib on CFVER>=1700 (our target 1900) so it is intentionally NOT built.
set -uo pipefail
cd /work/Procursus

echo "==> installing wave-1 recipes into makefiles/ (bumps override upstream)"
cp -v /work/recipes-ladybird/*.mk makefiles/

echo "==> installing wave-1 control templates into build_info/"
cp -v /work/build_info-ladybird/*.control build_info/

echo "==> installing -Wno-unused-command-line-argument clang wrappers"
cat > build_tools/cc-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
EOF
cat > build_tools/cxx-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
EOF
chmod +x build_tools/cc-nounused build_tools/cxx-nounused

COMMON="MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900 NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

mkdir -p /out
declare -A RESULT

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

# Tier 0 (no intra-closure deps)
for p in zlib brotli libtommath libfmt sqlite3 simdutf simdjson fast-float mimalloc wuffs; do
  build_one "$p"
done
# Tier 1 (need Tier 0 in BUILD_BASE)
for p in libxml2 woff2; do
  build_one "$p"
done

echo ""
echo "==> collect debs -> /out"
for pat in libz zlib brotli libbrotli libtommath libfmt sqlite3 libsqlite3 lemon \
           simdutf simdjson fast-float mimalloc libmimalloc wuffs libxml2 woff2 libwoff2; do
  find . -name "${pat}*_*_iphoneos-arm64.deb" -newermt "-6 hours" -exec cp -v {} /out/ \; 2>/dev/null || true
done

echo ""
echo "==================== WAVE 1 SUMMARY ===================="
for p in zlib brotli libtommath libfmt sqlite3 simdutf simdjson fast-float mimalloc wuffs libxml2 woff2; do
  printf '  %-14s %s\n' "$p" "${RESULT[$p]:-SKIPPED}"
done
echo "========================================================"
echo "==> done"
