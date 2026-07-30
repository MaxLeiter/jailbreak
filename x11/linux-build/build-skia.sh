#!/usr/bin/env bash
# Build a raster-only static libskia.a (+ libskcms.a) for iphoneos-arm64, for the
# Ladybird-on-iOS port (wall #2). Standalone driver in the house build-*.sh style
# (like build-mutter.sh / build-bun-ios.sh) — Skia is GN+ninja, does not fit the
# Procursus recipe mold, and produces no deb of its own (it links into Ladybird).
#
# Authoritative design: x11/docs/ladybird-skia-recipe.md. Read that first.
#
# Runs INSIDE the derived cross-build image (procursus-xbuild:skia — the base image
# plus the committed clang-19 layer + nasm). Drive with:
#
#   docker run --rm --platform linux/arm64 \
#     -v skia-ios-vol:/work/skia \
#     -v "$PWD/build-skia.sh:/work/build-skia.sh:ro" \
#     -v "$PWD/out:/out" \
#     procursus-xbuild:skia /work/build-skia.sh
#
# (image ENTRYPOINT is /bin/bash so the bare path runs under bash; needed for
#  pipefail. Named volume skia-ios-vol persists the ~GB Skia checkout + externals
#  across runs so git-sync-deps and the compile are not repeated.)
#
# Env knobs:
#   SKIA_WORK   working dir for the checkout (default /work/skia)
#   OUT         staging output prefix (default /out/skia-ios-arm64)
#   JOBS        ninja parallelism (default nproc)
#   GATE_ONLY=1 stop after gn gen + first ~30 TUs (toolchain-mechanics gate)
set -euo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
umask 022
export LC_ALL=C
export TZ=UTC

# -------- pins (from ladybird-skia-recipe.md §1) ------------------------------
SKIA_REPO="https://skia.googlesource.com/skia.git"
# Skia "144" == chrome milestone m144. vcpkg port 144 -> upstream commit:
SKIA_COMMIT="ee20d565acb08dece4a32e3f209cdd41119015ca"

SDK="/root/cctools/SDK/iPhoneOS16.5.sdk"      # staged sysroot in the image
IOS_MIN="16.0"

SKIA_WORK="${SKIA_WORK:-/work/skia}"
SRC="$SKIA_WORK/skia"
OUT="${OUT:-/out/skia-ios-arm64}"
JOBS="${JOBS:-$(nproc)}"
BUILDDIR="out/ios-arm64"

[ -d "$SDK" ] || { echo "FAIL: SDK not found at $SDK" >&2; exit 1; }

# -------- host tools (§3, §6) -------------------------------------------------
# clang-19 comes from the derived image. nasm is needed for bundled libjpeg-turbo
# SIMD; ensure it (and it alone) is present without a full apt dance if baked in.
command -v nasm >/dev/null 2>&1 || { apt-get update && apt-get install -y --no-install-recommends nasm && rm -rf /var/lib/apt/lists/*; }
command -v clang-19  >/dev/null 2>&1 || { echo "FAIL: clang-19 not in image (build the derived clang-19 image)" >&2; exit 1; }
command -v clang++-19 >/dev/null 2>&1 || { echo "FAIL: clang++-19 not in image" >&2; exit 1; }
command -v ninja >/dev/null 2>&1 || { echo "FAIL: ninja missing" >&2; exit 1; }

# -------- PATH shim: libtool + triple-pinned clang wrappers (§2a, §2b) --------
# GN's iOS archive rule hardcodes the bare name `libtool` and calls
# `libtool -static -o ... -no_warning_for_no_symbols` (cctools semantics). The
# Debian image's GNU libtool-bin (/usr/bin/libtool) is a different program and
# would choke, so shadow it with cctools' aarch64-apple-darwin-libtool. The
# skia-cc/skia-cxx wrappers pin the Darwin/iOS triple onto bare upstream clang-19
# (house cc-nounused style: also swallow the unused-arg warnings Skia's redundant
# -arch/-miphoneos-version-min would raise).
SHIM="$SKIA_WORK/shim"
mkdir -p "$SHIM"
ln -sf "$(command -v aarch64-apple-darwin-libtool)" "$SHIM/libtool"
cat > "$SHIM/skia-cc" <<EOF
#!/usr/bin/env bash
exec clang-19 --target=arm64-apple-ios${IOS_MIN} -isysroot ${SDK} -Wno-unused-command-line-argument "\$@"
EOF
cat > "$SHIM/skia-cxx" <<EOF
#!/usr/bin/env bash
exec clang++-19 --target=arm64-apple-ios${IOS_MIN} -isysroot ${SDK} -Wno-unused-command-line-argument "\$@"
EOF
chmod +x "$SHIM/skia-cc" "$SHIM/skia-cxx"
export PATH="$SHIM:$PATH"
echo "==> libtool resolves to: $(command -v libtool)  ($(readlink -f "$(command -v libtool)"))"

# -------- fetch Skia @ m144 + bundled externals (§1, §3) ----------------------
mkdir -p "$SKIA_WORK"
if [ ! -d "$SRC/.git" ]; then
  echo "==> cloning Skia"
  git clone "$SKIA_REPO" "$SRC"
fi
git -C "$SRC" fetch --quiet origin "$SKIA_COMMIT" || git -C "$SRC" fetch --quiet origin
git -C "$SRC" checkout --quiet "$SKIA_COMMIT"
git -C "$SRC" reset --quiet --hard "$SKIA_COMMIT"
echo "==> Skia at $(git -C "$SRC" rev-parse --short HEAD)"

echo "==> tools/git-sync-deps (bundled externals: freetype/harfbuzz/icu/libpng/zlib/expat/libjpeg-turbo/wuffs)"
# git-sync-deps does a shallow fetch of each dep's exact pinned SHA in parallel.
# Some git servers intermittently refuse to serve an arbitrary SHA in a shallow
# want ("nonexistent object ... / Thread failure detected"), which is transient.
# It is idempotent + resumable, so retry a few times before giving up.
gsd_ok=0
for attempt in 1 2 3 4 5; do
  if ( cd "$SRC" && python3 tools/git-sync-deps ); then gsd_ok=1; break; fi
  echo "==> git-sync-deps attempt $attempt failed (transient shallow-fetch); retrying"
  sleep 3
done
[ "$gsd_ok" = 1 ] || { echo "FAIL: git-sync-deps did not converge after retries" >&2; exit 1; }

# gn: use Skia's own fetched gn (bin/fetch-gn drops bin/gn). ninja from the image.
if [ ! -x "$SRC/bin/gn" ]; then
  echo "==> fetch gn"
  ( cd "$SRC" && python3 bin/fetch-gn )
fi

# -------- gn args (raster-only ios/arm64, static) — §2c ----------------------
# One clearly-commented block. Ganesh CORE stays ON (§4) with every GPU backend
# OFF, so GrDirectContext / SkSurfaces::RenderTarget resolve at link (Ladybird
# references them unconditionally) while no Metal/GL/Vulkan TU is pulled.
read -r -d '' GN_ARGS <<EOF || true
  target_os="ios"
  target_cpu="arm64"
  ios_min_target="${IOS_MIN}"

  # xcrun bypass (§2a): setting xcode_sysroot short-circuits the is_ios &&
  # xcode_sysroot=="" guard in gn/skia/BUILD.gn, so find_xcode_sysroot.py (the
  # sole xcrun call on the :skia path) never runs. Skia then injects
  # -isysroot / -arch arm64 / -miphoneos-version-min itself.
  xcode_sysroot="${SDK}"

  # Compiler: bare upstream clang-19 pinned to the iOS triple via wrappers.
  cc="${SHIM}/skia-cc"
  cxx="${SHIM}/skia-cxx"
  ar="aarch64-apple-darwin-ar"   # form only; iOS path uses libtool -static

  is_official_build=true
  is_component_build=false
  is_debug=false

  # --- Ganesh core ON, ALL GPU backends OFF (§4: link vs runtime) ----------
  skia_enable_ganesh=true
  skia_use_gl=false
  skia_use_metal=false
  skia_use_vulkan=false
  skia_use_dawn=false
  skia_use_direct3d=false
  skia_enable_graphite=false

  # --- Font raster: force FreeType (iOS defaults to CoreText) --------------
  skia_use_freetype=true
  skia_use_system_freetype2=false
  skia_use_fontconfig=false
  skia_use_harfbuzz=true
  skia_use_system_harfbuzz=false
  skia_use_icu=true
  skia_use_system_icu=false

  # --- Bundle everything else ---------------------------------------------
  skia_use_zlib=true
  skia_use_system_zlib=false
  skia_use_expat=true
  skia_use_system_expat=false
  skia_use_libpng_decode=true
  skia_use_libpng_encode=true
  skia_use_system_libpng=false
  skia_use_libjpeg_turbo_decode=true
  skia_use_libjpeg_turbo_encode=false
  skia_use_no_jpeg_encode=true
  skia_use_system_libjpeg_turbo=false
  skia_use_libwebp_decode=false
  skia_use_libwebp_encode=false
  skia_use_no_webp_encode=true
  skia_use_wuffs=true

  # --- Trim what Ladybird does not consume --------------------------------
  skia_enable_pdf=false
  skia_enable_svg=false
  skia_enable_skottie=false
  skia_enable_tools=false
  skia_enable_android_utils=false
  skia_enable_spirv_validation=false
  skia_enable_gpu_debug_layers=false
  skia_use_lua=false
  skia_use_dng_sdk=false
  skia_use_jpeg_gainmaps=false

  extra_cflags=["-DSKCMS_DLL"]
  extra_cflags_cc=["-DSKCMS_DLL","-USK_HIDE_PATH_EDIT_METHODS"]
EOF

echo "==> gn gen $BUILDDIR"
( cd "$SRC" && ./bin/gn gen "$BUILDDIR" --args="$GN_ARGS" )
echo "==> gn gen OK"
( cd "$SRC" && ./bin/gn ls "$BUILDDIR" >/dev/null ) && echo "==> gn graph resolves"

# -------- gate: prove clang-19 + xcrun-bypass + libtool + ld64 on real TUs ----
# GATE_ONLY builds a bounded ~40-object slice (fail-fast, no -k) so a broken
# toolchain surfaces immediately without paying for the full compile.
if [ "${GATE_ONLY:-0}" = "1" ]; then
  echo "==> GATE_ONLY: compiling a bounded TU slice (toolchain mechanics)"
  # SIGPIPE-safe slice extraction (awk cap, no `head`, tolerate pipefail).
  SLICE="$( cd "$SRC" && ninja -C "$BUILDDIR" -t targets all 2>/dev/null \
            | awk -F: '/\.o$|\.o:/ {sub(/:$/,"",$1); print $1; if(++n>=40) exit}' || true )"
  [ -n "$SLICE" ] || { echo "FAIL: could not enumerate object targets" >&2; exit 1; }
  ( cd "$SRC" && ninja -C "$BUILDDIR" -j"$JOBS" $SLICE )
  echo "==> gate slice compiled clean (40 objects): toolchain mechanics OK"
  exit 0
fi

# -------- full build ----------------------------------------------------------
# Single fail-fast ninja invocation (no -k): a toolchain-mechanical failure
# stops at the first TU, so watching the head of this log IS the early-TU gate.
echo "==> ninja -C $BUILDDIR skia (full build, long)"
( cd "$SRC" && ninja -C "$BUILDDIR" -j"$JOBS" skia )

LIBSKIA="$SRC/$BUILDDIR/libskia.a"
[ -f "$LIBSKIA" ] || { echo "FAIL: $LIBSKIA not produced" >&2; exit 1; }
echo "==> built $LIBSKIA ($(du -h "$LIBSKIA" | cut -f1))"

# libskcms may be a separate archive or folded into libskia depending on config.
LIBSKCMS="$SRC/$BUILDDIR/libskcms.a"
[ -f "$LIBSKCMS" ] && echo "==> built $LIBSKCMS ($(du -h "$LIBSKCMS" | cut -f1))" || echo "==> (no separate libskcms.a — skcms folded into libskia.a)"

# Skia's iOS-device config (gn/skia/BUILD.gn) injects -arch arm64 -arch arm64e, so
# the archives come out fat (arm64 + arm64e). The A10 target is strictly arm64 (no
# pointer-auth/arm64e) and the whole toolchain targets arm64, so thin to arm64 for a
# lean, unambiguous deliverable. (Linking the fat archive would also work — ld picks
# the arm64 slice — this just halves size and removes the arm64e surprise.)
LIPO="$(command -v aarch64-apple-darwin-lipo || true)"
if [ -n "$LIPO" ] && "$LIPO" "$LIBSKIA" -verify_arch arm64e 2>/dev/null; then
  echo "==> fat archive detected; thinning to arm64 (A10 target)"
  "$LIPO" "$LIBSKIA" -thin arm64 -output "$LIBSKIA.arm64" && mv "$LIBSKIA.arm64" "$LIBSKIA"
  if [ -f "$LIBSKCMS" ] && "$LIPO" "$LIBSKCMS" -verify_arch arm64e 2>/dev/null; then
    "$LIPO" "$LIBSKCMS" -thin arm64 -output "$LIBSKCMS.arm64" && mv "$LIBSKCMS.arm64" "$LIBSKCMS"
  fi
  echo "==> thinned libskia.a ($(du -h "$LIBSKIA" | cut -f1))"
fi

# -------- PathOps splice (FOLDED from build-skia-pathops.sh, 2026-07-03) -------
# `ninja skia` does NOT compile src/pathops/*.cpp, so Op(SkPath,SkPath,SkPathOp) (SkPathOps boolean
# ops, referenced by LibWeb for clip-path / CSS geometry) is an undefined symbol at WebContent/
# WebWorker link. Compile the ~32 pathops TUs with Skia's own core flags and ar them into libskia.a
# so the staged archive is always link-complete (no separate post-splice step).
echo "==> splicing src/pathops/*.cpp into libskia.a"
PO_AR="$(command -v aarch64-apple-darwin-ar || command -v ar)"
PO_DEFS="-DNDEBUG -DSK_CODEC_DECODES_BMP -DSK_CODEC_DECODES_WBMP -DSK_HIDE_PATH_EDIT_METHODS \
-DSK_ENABLE_PRECOMPILE -DSK_ASSUME_GL_ES=1 -DSK_GANESH -DSK_DISABLE_TRACING -DSK_ENABLE_API_AVAILABLE \
-DSK_GAMMA_APPLY_TO_A8 -DSK_DISABLE_LEGACY_NONCONST_SERIAL_PROCS -DSK_ENABLE_AVX512_OPTS \
-DSKIA_IMPLEMENTATION=1 -DSK_FONTMGR_CORETEXT_AVAILABLE -DSK_TYPEFACE_FACTORY_CORETEXT"
PO_FLAGS="-I$SRC -Wno-attributes -ffp-contract=off -fPIC -fvisibility=hidden \
-arch arm64 -miphoneos-version-min=${IOS_MIN} -fstrict-aliasing -O3 -fvisibility-inlines-hidden \
-std=c++20 -stdlib=libc++ -fno-aligned-allocation -fno-exceptions -fno-rtti -USK_HIDE_PATH_EDIT_METHODS"
PO_OBJDIR="$SKIA_WORK/pathops-obj"; rm -rf "$PO_OBJDIR"; mkdir -p "$PO_OBJDIR"
po_n=0
for f in "$SRC"/src/pathops/*.cpp; do
  bn="$(basename "$f" .cpp)"
  "$SHIM/skia-cxx" $PO_DEFS $PO_FLAGS -c "$f" -o "$PO_OBJDIR/pathops.$bn.o" || { echo "FAIL pathops $bn" >&2; exit 1; }
  po_n=$((po_n+1))
done
"$PO_AR" rs "$LIBSKIA" "$PO_OBJDIR"/*.o
echo "==> spliced $po_n pathops objects; libskia.a = $(du -h "$LIBSKIA" | cut -f1)"

# -------- #1 risk: verify Ganesh-core symbols present-and-defined (§4, §8.1) --
echo "==> nm verdict on unconditionally-linked Ganesh symbols"
NM="$(command -v aarch64-apple-darwin-nm || command -v nm)"
"$NM" "$LIBSKIA" 2>/dev/null > "$SKIA_WORK/nm-libskia.txt" || true
for sym in RenderTarget GrDirectContext getResourceCacheUsage; do
  echo "--- $sym ---"
  grep -E " [TtWwSs] .*${sym}" "$SKIA_WORK/nm-libskia.txt" | head -5 || echo "   (none defined)"
done

# -------- stage output (§5) ---------------------------------------------------
echo "==> staging into $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include/skia"
cp "$LIBSKIA" "$OUT/lib/libskia.a"
[ -f "$LIBSKCMS" ] && cp "$LIBSKCMS" "$OUT/lib/libskcms.a"

# Header tree (mirrors Ladybird flatpak skia-install.sh layout, plus vcpkg's
# src/*.h copy for the public headers that include "src/..." privates):
#   $OUT/include/skia/{core,gpu/ganesh,...}   <- Skia include/*
#   $OUT/include/skia/modules/                <- Skia modules/*.h
#   $OUT/include/skia/src/                    <- Skia src/*.h
cp -a "$SRC/include/." "$OUT/include/skia/"
# modules headers
mkdir -p "$OUT/include/skia/modules"
( cd "$SRC/modules" && find . -name '*.h' -print0 | cpio -0 -pdm "$OUT/include/skia/modules/" ) 2>/dev/null || \
  ( cd "$SRC" && rsync -am --include='*/' --include='*.h' --exclude='*' modules/ "$OUT/include/skia/modules/" )
# src headers (vcpkg parity / safety)
mkdir -p "$OUT/include/skia/src"
( cd "$SRC" && rsync -am --include='*/' --include='*.h' --exclude='*' src/ "$OUT/include/skia/src/" ) 2>/dev/null || \
  ( cd "$SRC/src" && find . -name '*.h' -print0 | cpio -0 -pdm "$OUT/include/skia/src/" )
# skcms public header (LibGfx/ColorSpace.cpp needs skcms.h). skcms.h lives at
# modules/skcms/skcms.h and does #include "src/skcms_public.h" relative to itself,
# so stage skcms.h at the include root AND its src/*.h under include/skia/src/ so
# that relative include resolves.
cp "$SRC/modules/skcms/skcms.h" "$OUT/include/skia/skcms.h"
mkdir -p "$OUT/include/skia/src"
cp "$SRC/modules/skcms/src/"*.h "$OUT/include/skia/src/"

# Flatpak fixup (§5): Skia's public headers include each other root-relative as
#   #include "include/core/SkFoo.h"
# but Ladybird gets -I$PREFIX/include/skia and includes <core/SkFoo.h>. Strip the
# leading include/ so those internal includes resolve against the same -I. The
# src/ and modules/ prefixes are left intact (staged as subtrees above).
echo "==> rewriting #include \"include/...\" -> #include \"...\" across staged headers"
grep -rlZ '#include "include/' "$OUT/include/skia" 2>/dev/null \
  | xargs -0 -r sed -i 's|#include "include/|#include "|g'

# skia.pc (§5) — Version 144, empty Requires (bundled deps archived in).
# Apple-framework closure (§5 risk / §8.5): a global-undefined survey of libskia.a
# (nm: U-in-some-member, defined-in-none) shows it references CoreFoundation (~45),
# CoreGraphics (~40), CoreText (~41, from the compiled-in SkFontMgr_mac_ct alongside
# freetype), ImageIO (~3, CGImageSource/Destination), and libobjc (1). No Foundation/
# UIKit/Metal symbols (confirms zero GPU/Metal closure). All are REQUIRED — none trims
# — so bake them into Libs so PkgConfig::skia hands Ladybird a complete link closure.
cat > "$OUT/lib/pkgconfig-skia.pc" <<'PC'
prefix=$XIOS_PREFIX
exec_prefix=${prefix}
libdir=${prefix}/lib
includedir=${prefix}/include/skia

Name: skia
Description: 2D graphic library for drawing text, geometries and images.
URL: https://skia.org/
Version: 144
Libs: -L${libdir} -lskia -lskcms -lobjc -framework CoreFoundation -framework CoreGraphics -framework CoreText -framework ImageIO
Cflags: -I${includedir}
PC
mkdir -p "$OUT/lib/pkgconfig"
cp "$OUT/lib/pkgconfig-skia.pc" "$OUT/lib/pkgconfig/skia.pc"
rm -f "$OUT/lib/pkgconfig-skia.pc"

echo "==> staged:"
ls -l "$OUT/lib"
echo "==> header roots:"; ls "$OUT/include/skia" | head
echo "==> DONE. libskia.a = $(du -h "$OUT/lib/libskia.a" | cut -f1)"
