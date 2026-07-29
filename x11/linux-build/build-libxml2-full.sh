#!/usr/bin/env bash
# Rebuild libxml2 2.13.8 with every optional module enabled, so the deb that shadows
# Procursus libxml2 is a strict superset of it instead of a subset.
#
#   docker run --rm --platform linux/arm64 \
#     -v procursus-vol-ladybird:/work/Procursus \
#     -v "$PWD/build-libxml2-full.sh:/work/build-libxml2-full.sh:ro" \
#     -v "$PWD/recipes-ladybird:/work/recipes-ladybird:ro" \
#     -v "$PWD/build_info-ladybird:/work/build_info-ladybird:ro" \
#     -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 /work/build-libxml2-full.sh
#
# Why: libxml2 2.13 flipped http/ftp/legacy/lzma to default-off, +ios1 took the
# defaults, and the deb kept the Procursus package name. Installing it removed
# _xmlNanoHTTP* (and the legacy entity API, and the __libxml2_xz* internals), which
# breaks our own libgsf-1-114 and Procursus's python3-libxml2 at dyld. Same class of
# bug as harfbuzz 10.2.0+ios1; see build-harfbuzz-full.sh.
#
# The DocBook SAX entry points (docb*) cannot come back: deleted upstream at 2.12.
set -uo pipefail
cd /work/Procursus

echo "==> installing the full-module libxml2 recipe into makefiles/"
cp -v /work/recipes-ladybird/libxml2.mk makefiles/

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

COMMON="MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900 NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

BW=/work/Procursus/build_work/iphoneos-arm64-rootless/1900
BS=/work/Procursus/build_stage/iphoneos-arm64-rootless/1900
BB=/work/Procursus/build_base/iphoneos-arm64-rootless/1900/var/jb
mkdir -p /out

# The recipe caches on .build_complete and configure -C caches on config.cache, so a
# flag change alone would silently reuse the old build. Wipe both trees and the staged
# shadow, exactly like the wave scripts do.
echo "--- wiping stale libxml2 (build_work + build_stage + build_base)"
rm -rf "$BW/libxml2" "$BS/libxml2"
rm -rf $BB/usr/lib/libxml2.* $BB/usr/lib/pkgconfig/libxml-2.0.pc \
       $BB/usr/include/libxml2 $BB/usr/lib/cmake/libxml2 \
       $BB/usr/bin/xmllint $BB/usr/bin/xmlcatalog $BB/usr/bin/xml2-config

echo ""
echo "==> make libxml2-package"
if make libxml2-package $COMMON -j"$(nproc)"; then
  RESULT=OK
else
  RESULT=FAILED
fi

echo ""
echo "==> collect debs -> /out"
for pat in libxml2 libxml2-dev libxml2-utils; do
  find . -name "${pat}_*_iphoneos-arm64.deb" -newermt "-8 hours" -exec cp -v {} /out/ \; 2>/dev/null || true
done

echo ""
echo "==================== LIBXML2 SUMMARY ===================="
printf '  %-16s %s\n' libxml2 "$RESULT"
echo "========================================================="
[ "$RESULT" = OK ]
