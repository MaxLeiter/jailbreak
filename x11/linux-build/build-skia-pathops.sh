#!/usr/bin/env bash
# Splice Skia PathOps into the already-built libskia.a. build-skia.sh's raster-only `ninja skia`
# target does NOT include src/pathops/*, so `Op(SkPath, SkPath, SkPathOp)` (SkPathOps boolean ops,
# used by LibWeb for clip-path/CSS geometry) is an undefined symbol at WebContent/WebWorker link.
# Rather than a full Skia rebuild, compile the 32 pathops TUs with Skia's own flags and ar them into
# the staged arm64 libskia.a.
#
#   docker run --rm --platform linux/arm64 \
#     -v skia-ios-vol:/work/skia -v "$PWD/build-skia-pathops.sh:/work/build-skia-pathops.sh:ro" \
#     -v "$PWD/out:/out" procursus-xbuild:skia -c /work/build-skia-pathops.sh
set -euo pipefail
SRC=/work/skia/skia
BD=out/ios-arm64
LIBSKIA=/out/skia-ios-arm64/lib/libskia.a
AR=/root/cctools/bin/aarch64-apple-darwin-ar
NM=/root/cctools/bin/aarch64-apple-darwin-nm
CXX=/work/skia/shim/skia-cxx
cd "$SRC"

# The exact define/flag set Skia compiles its own core TUs with (from `ninja -t commands`), minus the
# fat arm64e slice (the staged libskia.a was lipo-thinned to arm64 for the A10 target).
DEFS="-DNDEBUG -DSK_CODEC_DECODES_BMP -DSK_CODEC_DECODES_WBMP -DSK_HIDE_PATH_EDIT_METHODS \
-DSK_ENABLE_PRECOMPILE -DSK_ASSUME_GL_ES=1 -DSK_GANESH -DSK_DISABLE_TRACING -DSK_ENABLE_API_AVAILABLE \
-DSK_GAMMA_APPLY_TO_A8 -DSK_DISABLE_LEGACY_NONCONST_SERIAL_PROCS -DSK_ENABLE_AVX512_OPTS \
-DSKIA_IMPLEMENTATION=1 -DSK_FONTMGR_CORETEXT_AVAILABLE -DSK_TYPEFACE_FACTORY_CORETEXT"
FLAGS="-I$SRC -Wno-attributes -ffp-contract=off -fPIC -fvisibility=hidden \
-isysroot /root/cctools/SDK/iPhoneOS16.5.sdk -arch arm64 -miphoneos-version-min=16.0 \
-fstrict-aliasing -O3 -fvisibility-inlines-hidden -std=c++20 -stdlib=libc++ \
-fno-aligned-allocation -fno-exceptions -fno-rtti -USK_HIDE_PATH_EDIT_METHODS"

OBJDIR=/tmp/pathops-obj; rm -rf "$OBJDIR"; mkdir -p "$OBJDIR"
n=0
for f in src/pathops/*.cpp; do
  bn=$(basename "$f" .cpp)
  "$CXX" $DEFS $FLAGS -c "$f" -o "$OBJDIR/pathops.$bn.o" || { echo "FAIL $bn"; exit 1; }
  n=$((n+1))
done
echo "compiled $n pathops objects"

echo "== libskia.a BEFORE: $(du -h "$LIBSKIA" | cut -f1) =="
"$AR" rs "$LIBSKIA" "$OBJDIR"/*.o
echo "== libskia.a AFTER:  $(du -h "$LIBSKIA" | cut -f1) =="

echo "== Op() now defined? =="
"$NM" "$LIBSKIA" 2>/dev/null | grep -E " T __Z2OpRK6SkPath" | head || echo "!! Op still missing"
# also refresh the working-tree copy the recipe reads, for consistency
cp "$LIBSKIA" "$SRC/$BD/libskia.a" 2>/dev/null || true
echo "== DONE =="
