#!/usr/bin/env bash
# Wave 4b — finish M0: close the AsmInterpreter host-tool wall, compile LibWeb, link WebContent +
# WebWorker, build a headless PNG driver, and package the iphoneos-arm64 deb.
#
# Continues the state left by build-ladybird-wave4.sh on procursus-vol-ladybird:
#   - ladybird-src : cloned + M0-patched
#   - ladybird-build : configured (no vcpkg), 28 Lagom libs + Skia compiled, ImageDecoder +
#     RequestServer already linked; build stopped at LibJS AsmInterpreter (gen_asm_offsets +
#     asmintgen cross-compiled for iOS -> Exec format error on the Linux host).
#
#   docker run --rm --platform linux/arm64 \
#     -v procursus-vol-ladybird:/work/Procursus \
#     -v "$PWD/build-ladybird-wave4b.sh:/work/build-ladybird-wave4b.sh:ro" \
#     -v "$PWD/recipes-ladybird:/work/recipes-ladybird:ro" \
#     -v "$PWD/out:/out" \
#     procursus-xbuild:skia -c /work/build-ladybird-wave4b.sh
#
# THE fix (native-then-cross, same shape as ICU host tooling): build gen_asm_offsets (C++/AK) and
# asmintgen (Rust) NATIVELY for the arm64 build host, then point LibJS's two add_custom_command
# COMMANDs at those host binaries (patch 12 in ladybird-m0-patches.sh, env-gated on LB_HOST_*).
# Host arm64 == target arm64 (both LP64) so gen_asm_offsets' struct offsets are layout-identical;
# asmintgen picks target asm from --arch aarch64 regardless of host. --has-jscvt is dropped for the
# A10 (ARMv8.1, no FEAT_JSCVT).
#
# Stages (LB_STAGE, default all): prep | hosttools | build | headless | package | all
set -uo pipefail

LB_STAGE="${LB_STAGE:-all}"
SDK=/root/cctools/SDK/iPhoneOS16.5.sdk
PROC=/work/Procursus
BB=$PROC/build_base/iphoneos-arm64-rootless/1900/var/jb
SHIM=/work/shim
WORK=$PROC/ladybird-src
BUILD=$PROC/ladybird-build
HOST=$PROC/ladybird-hosttools
export RUSTUP_HOME=$PROC/build_tools/rustup
export CARGO_HOME=$PROC/build_tools/cargo
export PATH=$CARGO_HOME/bin:$PATH
mkdir -p /out

step() { echo; echo "########## $* ##########"; }
run_stage() { case "$LB_STAGE" in all) return 0;; "$1") return 0;; *) return 1;; esac; }

# ================================================================================================
step "STAGE prep: /var/jb symlink + shim toolchain + fake xcrun (idempotent, mirrors wave4)"
# ================================================================================================
if [ ! -e /var/jb ]; then ln -s "$BB" /var/jb; fi
ls -ld /var/jb
mkdir -p "$SHIM"
for t in ld ranlib libtool install_name_tool otool nm strip lipo dsymutil codesign_allocate \
         segedit size nmedit; do
  [ -e /root/cctools/bin/aarch64-apple-darwin-$t ] && ln -sf /root/cctools/bin/aarch64-apple-darwin-$t "$SHIM/$t"
done
# ar wrapper: CMake archives LibWeb's huge object list via `ar qc <lib> @response-file`, but cctools
# ar has no @response-file support (treats `@file` as a literal member name -> "No such file or
# directory"). Wrap ar to expand any @<file> arg (whitespace/newline-separated object paths) before
# handing off to cctools ar. Non-@ args (incl. the Rust-merge `ar -x`/`ar -qS *.o` steps) pass through.
cat > "$SHIM/ar" <<'EOF'
#!/bin/sh
# rotate through the ORIGINAL args exactly once (n times), popping from the front and pushing the
# processed result to the back; @<file> expands to the file's whitespace-separated contents.
n=$#
i=0
while [ "$i" -lt "$n" ]; do
  a=$1; shift
  case "$a" in
    @*) f="${a#@}"; for o in $(cat "$f"); do set -- "$@" "$o"; done ;;
    *)  set -- "$@" "$a" ;;
  esac
  i=$((i+1))
done
exec /root/cctools/bin/aarch64-apple-darwin-ar "$@"
EOF
chmod +x "$SHIM/ar"
cat > "$SHIM/lb-cc" <<EOF
#!/bin/sh
exec clang-19 --target=arm64-apple-ios16.0 -isysroot $SDK \
  -B$SHIM -fuse-ld=$SHIM/ld -D__IOS__ "\$@" -Wno-error
EOF
cat > "$SHIM/lb-cxx" <<EOF
#!/bin/sh
exec clang++-19 --target=arm64-apple-ios16.0 -isysroot $SDK -stdlib=libc++ \
  -B$SHIM -fuse-ld=$SHIM/ld -D__IOS__ "\$@" -Wno-error
EOF
cat > "$SHIM/xcrun" <<EOF
#!/bin/sh
for a in "\$@"; do case "\$a" in --show-sdk-path*) echo $SDK; exit 0;; esac; done
if [ "\$1" = "--find" ] || [ "\$1" = "-find" ]; then command -v "$SHIM/\$2" || command -v "\$2" || true; exit 0; fi
echo $SDK
EOF
cat > "$SHIM/sw_vers" <<'EOF'
#!/bin/sh
case "$1" in -productVersion) echo 13.4;; -buildVersion) echo 22F66;; *) echo macOS;; esac
EOF
chmod +x "$SHIM"/lb-cc "$SHIM"/lb-cxx "$SHIM"/xcrun "$SHIM"/sw_vers
ln -sf "$SHIM/xcrun" /usr/local/bin/xcrun
ln -sf "$SHIM/sw_vers" /usr/local/bin/sw_vers

# re-apply the M0 patch series (idempotent; adds patch 12 = AsmInterpreter host-tool split)
step "re-applying M0 patches (idempotent)"
bash /work/recipes-ladybird/ladybird-m0-patches.sh "$WORK"

# skia.pc framework-syntax fixup: the staged skia.pc lists four consecutive
#   `-framework CoreFoundation -framework CoreGraphics -framework CoreText -framework ImageIO`
# in Libs:. CMake's pkg_check_modules IMPORTED-target parser mis-splits consecutive `-framework`
# pairs -> keeps only `-framework CoreFoundation`, then passes CoreGraphics/CoreText/ImageIO as
# BARE filenames -> `clang: no such file or directory: 'CoreGraphics'` on link (ImageDecoder,
# WebContent, ...). All four frameworks DO exist on iOS; the only bug is the CMake mis-parse.
# Rewrite each to the opaque `-Wl,-framework,NAME` form, which CMake forwards verbatim and clang
# expands back to `-framework NAME` for ld64. (Mirror this fix into build-ladybird-wave4.sh deps
# so a fresh stage gets it too.)
SKIA_PC=$BB/usr/lib/pkgconfig/skia.pc
if [ -f "$SKIA_PC" ] && grep -q -- '-framework CoreFoundation -framework' "$SKIA_PC"; then
  sed -i 's/-framework \([A-Za-z0-9_]*\)/-Wl,-framework,\1/g' "$SKIA_PC"
  echo "  [fixup] skia.pc frameworks -> -Wl,-framework,NAME form"
  grep -h '^Libs:' "$SKIA_PC"
else
  echo "  [fixup] skia.pc frameworks already fixed or absent"
fi

# --- dependency gap-fills surfaced at WebContent/WebWorker link (Wave 1-3 build gaps) -------------
# (a) libskia.a: build-skia.sh's raster `ninja skia` omits src/pathops -> Op(SkPath,SkPath,SkPathOp)
#     undefined. build-skia-pathops.sh spliced the 32 pathops TUs into /out/skia-ios-arm64. Refresh
#     the staged copy so the link picks it up.
if [ -f /out/skia-ios-arm64/lib/libskia.a ] && \
   ! /root/cctools/bin/aarch64-apple-darwin-nm $BB/usr/lib/libskia.a 2>/dev/null | grep -q '__Z2OpRK6SkPath'; then
  cp /out/skia-ios-arm64/lib/libskia.a $BB/usr/lib/libskia.a
  echo "  [gapfill] refreshed staged libskia.a (now $(du -h $BB/usr/lib/libskia.a | cut -f1), pathops spliced)"
else
  echo "  [gapfill] libskia.a already has pathops or /out copy missing"
fi

# (b) SDL3 stub is missing 7 joystick/virtual-joystick symbols LibWeb's Gamepad code references.
#     Append no-op implementations to the staged libSDL3.a (M0: no controllers ever present).
if ! /root/cctools/bin/aarch64-apple-darwin-nm $BB/usr/lib/libSDL3.a 2>/dev/null | grep -q '_SDL_AttachVirtualJoystick'; then
  cat > /tmp/sdl3_extra.c <<'EOF'
#include <SDL3/SDL.h>
/* M0 headless: no joysticks/gamepads ever present. */
bool SDL_Init(SDL_InitFlags f){ (void)f; return true; }
SDL_Joystick *SDL_OpenJoystick(SDL_JoystickID id){ (void)id; return NULL; }
void SDL_CloseJoystick(SDL_Joystick *j){ (void)j; }
SDL_JoystickID SDL_AttachVirtualJoystick(const SDL_VirtualJoystickDesc *d){ (void)d; return 0; }
bool SDL_DetachVirtualJoystick(SDL_JoystickID id){ (void)id; return false; }
bool SDL_SetJoystickVirtualAxis(SDL_Joystick *j, int a, Sint16 v){ (void)j;(void)a;(void)v; return false; }
bool SDL_SetJoystickVirtualButton(SDL_Joystick *j, int b, bool d){ (void)j;(void)b;(void)d; return false; }
EOF
  "$SHIM/lb-cc" -std=c11 -I$BB/usr/include -c /tmp/sdl3_extra.c -o /tmp/sdl3_extra.o \
    && "$SHIM/ar" rs $BB/usr/lib/libSDL3.a /tmp/sdl3_extra.o \
    && echo "  [gapfill] added 7 SDL joystick stubs to libSDL3.a" || echo "  !! SDL3 extra stub FAILED"
else
  echo "  [gapfill] libSDL3.a already has joystick stubs"
fi

# (c) libtommath.dylib was built without mp_set_double (LibCrypto BigInteger::set_to_double uses it).
#     Compile the upstream bn_mp_set_double.c and stage it in a small static lib the exes link
#     (-lladybird_gapfill via the toolchain). It calls other tommath fns resolved from the dylib.
TM=$(dirname "$(find $PROC/build_work -path '*libtommath/bn_mp_set_double.c' 2>/dev/null | head -1)")
# NB: bn_mp_set_double.c compiles its real body only under __STDC_IEC_559__ (IEEE754); clang does not
# define it for arm64-apple-ios, so force it (arm64 IS IEEE754) or the object is empty.
if [ -n "$TM" ] && ! /root/cctools/bin/aarch64-apple-darwin-nm $BB/usr/lib/libladybird_gapfill.a 2>/dev/null | grep -q '_mp_set_double'; then
  "$SHIM/lb-cc" -O2 -DBN_MP_SET_DOUBLE_C -D__STDC_IEC_559__=1 -I"$TM" -c "$TM/bn_mp_set_double.c" -o /tmp/mp_set_double.o \
    && "$SHIM/libtool" -static -o $BB/usr/lib/libladybird_gapfill.a /tmp/mp_set_double.o \
    && echo "  [gapfill] staged libladybird_gapfill.a ($(/root/cctools/bin/aarch64-apple-darwin-nm $BB/usr/lib/libladybird_gapfill.a 2>/dev/null | grep -c mp_set_double) mp_set_double def)" \
    || echo "  !! mp_set_double build FAILED"
else
  echo "  [gapfill] libladybird_gapfill.a already has mp_set_double or tommath src missing"
fi

# ================================================================================================
step "STAGE hosttools: build gen_asm_offsets (C++/AK) + asmintgen (Rust) NATIVELY (arm64 host)"
# ================================================================================================
# Host-tool build needs LibJS's generated headers (Op.h/OpCodes.h etc). They exist in $BUILD after
# wave4's partial build; if absent, run a codegen ninja pass (it will fail at the asm step, which is
# exactly the wall we are closing, but everything upstream — including the generated headers — gets
# emitted first).
export LB_STAGED_PREFIX=/var/jb
export PKG_CONFIG_PATH=/var/jb/usr/lib/pkgconfig:/var/jb/usr/share/pkgconfig
export PKG_CONFIG_LIBDIR=/var/jb/usr/lib/pkgconfig:/var/jb/usr/share/pkgconfig
export LB_SHIM="$SHIM"

ensure_generated_headers() {
  if [ -f "$BUILD/Libraries/LibJS/Bytecode/OpCodes.h" ]; then
    echo "  generated headers present in \$BUILD"
    return 0
  fi
  echo "  generated headers MISSING -> configure + codegen pass"
  if [ ! -f "$BUILD/build.ninja" ]; then
    rm -rf "$BUILD"; mkdir -p "$BUILD"
    cmake -GNinja -B "$BUILD" -S "$WORK" \
      -DCMAKE_TOOLCHAIN_FILE=/work/recipes-ladybird/ios-toolchain.cmake \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DENABLE_GUI_TARGETS=ON \
      -DENABLE_INSTALL_HEADERS=OFF -DENABLE_NETWORK_DOWNLOADS=ON -DENABLE_CLANG_PLUGINS=OFF \
      -DENABLE_CRANELIFT_JIT=OFF -DRUST_TARGET_TRIPLE=aarch64-apple-ios \
      -DLADYBIRD_CACHE_DIR=/var/jb/lib/ladybird -DVCPKG_ROOT= 2>&1 | tail -5
  fi
  ( cd "$BUILD" && ninja -k 0 -j"$(nproc)" WebContent 2>&1 | tail -3 || true )
}

if run_stage hosttools && [ -x "$HOST/gen_asm_offsets" ] && [ -x "$HOST/asmintgen" ]; then
  echo "  host tools already built ($HOST/{gen_asm_offsets,asmintgen}); skipping rebuild"
elif run_stage hosttools; then
  ensure_generated_headers

  SIMD=$(dirname "$(find $PROC/build_work -name simdutf.cpp -path '*simdutf*' 2>/dev/null | head -1)")
  SIMD=${SIMD%/src}
  MIM=$(dirname "$(find $PROC/build_work -path '*mimalloc/src/static.c' 2>/dev/null | head -1)")
  MIM=${MIM%/src}
  FMT=$(dirname "$(find $PROC/build_work -path '*libfmt/src/format.cc' 2>/dev/null | head -1)")
  FMT=${FMT%/src}
  echo "  simdutf=$SIMD  mimalloc=$MIM  fmt=$FMT"

  rm -rf "$HOST"; mkdir -p "$HOST/ak"
  INC="-I$WORK -I$WORK/Libraries -I$WORK/Services -I$BUILD -I$BUILD/Libraries -I$BUILD/Services -idirafter $BB/usr/include"
  CXXFLAGS="-DENABLE_COMPILETIME_FORMAT_CHECK -DNDEBUG -fno-exceptions -std=c++2b -O1 -w $INC"

  echo "==> host libAK.a"
  n=0
  for f in "$WORK"/AK/*.cpp; do
    bn=$(basename "$f" .cpp)
    case $bn in DemangleWindows|LexicalPathWindows) continue;; esac
    clang++-19 $CXXFLAGS -c "$f" -o "$HOST/ak/$bn.o" 2>"$HOST/ak/$bn.err" \
      || { echo "  !! host AK FAIL $bn"; tail -20 "$HOST/ak/$bn.err"; exit 1; }
    n=$((n+1))
  done
  ar rcs "$HOST/libAK.a" "$HOST"/ak/*.o
  echo "  libAK.a: $n objects"

  echo "==> host simdutf / mimalloc / fmt (runtime deps of AK)"
  clang++-19 -O1 -w -std=c++17 -I"$SIMD/include" -I"$SIMD/src" -c "$SIMD/src/simdutf.cpp" -o "$HOST/simdutf.o" \
    || { echo "  !! simdutf FAIL"; exit 1; }
  clang-19 -O1 -w -DNDEBUG -I"$MIM/include" -c "$MIM/src/static.c" -o "$HOST/mimalloc.o" \
    || { echo "  !! mimalloc FAIL"; exit 1; }
  clang++-19 -O1 -w -std=c++20 -I"$FMT/include" -c "$FMT/src/format.cc" -o "$HOST/fmt.o" \
    || { echo "  !! fmt FAIL"; exit 1; }

  echo "==> host gen_asm_offsets (private/protected exposed for offsetof)"
  clang++-19 $CXXFLAGS -Dprivate=public -Dprotected=public \
    "$WORK/Libraries/LibJS/Bytecode/AsmInterpreter/gen_asm_offsets.cpp" \
    "$HOST/libAK.a" "$HOST/simdutf.o" "$HOST/mimalloc.o" "$HOST/fmt.o" -lpthread \
    -o "$HOST/gen_asm_offsets" || { echo "  !! gen_asm_offsets link FAIL"; exit 1; }
  file "$HOST/gen_asm_offsets"

  echo "==> host asmintgen (cargo, aarch64-unknown-linux-gnu)"
  ( cd "$WORK/Libraries/LibJS/AsmIntGen" && cargo build --release --target aarch64-unknown-linux-gnu 2>&1 | tail -3 )
  cp "$WORK/Libraries/LibJS/AsmIntGen/target/aarch64-unknown-linux-gnu/release/asmintgen" "$HOST/asmintgen"
  file "$HOST/asmintgen"

  echo "==> smoke-run both host tools"
  "$HOST/gen_asm_offsets" > "$HOST/asm_offsets.conf" && echo "  asm_offsets.conf: $(wc -l < "$HOST/asm_offsets.conf") lines"
  "$HOST/asmintgen" --arch aarch64 --object-format macho \
    --constants "$HOST/asm_offsets.conf" \
    --bytecode-def "$WORK/Libraries/LibJS/Bytecode/Bytecode.def" \
    --input "$WORK/Libraries/LibJS/Bytecode/AsmInterpreter/asmint.asm" \
    --output "$HOST/asmint_aarch64.S" && echo "  asmint_aarch64.S: $(wc -l < "$HOST/asmint_aarch64.S") lines; fjcvtzs=$(grep -c fjcvtzs "$HOST/asmint_aarch64.S" || true)"
fi

# these must be visible to the configure below so patch 12's env-gated branches fire.
export LB_HOST_GEN_ASM_OFFSETS="$HOST/gen_asm_offsets"
export LB_HOST_ASMINTGEN="$HOST/asmintgen"

# ================================================================================================
step "STAGE build: reconfigure (pick up patch 12 + LB_HOST_*) then compile LibWeb + link helpers"
# ================================================================================================
export LB_STAGED_PREFIX=/var/jb
if run_stage build; then
  cd "$WORK"
  # FRESH configure: drop CMakeCache.txt so pkg_check_modules re-parses the fixed skia.pc (its
  # -Wl,-framework,NAME frameworks; the stale cache kept the old plain -framework list, which CMake's
  # link de-dup collapsed into one -framework + bare CoreGraphics/CoreText/ImageIO -> link failure).
  # Compiled objects under CMakeFiles/*.dir persist and ninja reuses them (compile commands unchanged).
  rm -f "$BUILD/CMakeCache.txt"
  cmake -GNinja -B "$BUILD" -S "$WORK" \
    -DCMAKE_TOOLCHAIN_FILE=/work/recipes-ladybird/ios-toolchain.cmake \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DENABLE_GUI_TARGETS=ON \
    -DENABLE_INSTALL_HEADERS=OFF -DENABLE_NETWORK_DOWNLOADS=ON -DENABLE_CLANG_PLUGINS=OFF \
    -DENABLE_CRANELIFT_JIT=OFF -DRUST_TARGET_TRIPLE=aarch64-apple-ios \
    -DLADYBIRD_CACHE_DIR=/var/jb/lib/ladybird -DVCPKG_ROOT= 2>&1 | tail -6
  echo "reconfigure exit: ${PIPESTATUS[0]}"

  cd "$BUILD"
  TARGETS="WebContent RequestServer ImageDecoder WebWorker headless-shot"
  # Pass 1: full parallelism, keep-going to enumerate any remaining source walls in one shot.
  ninja -k 0 -j"$(nproc)" $TARGETS 2>&1 | tee /out/wave4b-build.log
  p1=${PIPESTATUS[0]}
  # Pass 2: some LibWebView/LibWeb TUs (e.g. ViewImplementation.cpp) are ~3GB at -O3 and get
  # OOM-killed ("Killed") under -j16 on this 7.7GiB VM. Retry the few remaining actions at low
  # parallelism so the giants compile with headroom. Cached objects make this fast.
  if [ "$p1" -ne 0 ]; then
    echo "== pass 1 exit $p1; low-parallelism retry (-j2) for OOM-killed TUs =="
    ninja -k 0 -j2 $TARGETS 2>&1 | tee -a /out/wave4b-build.log
    echo "build exit (pass2): ${PIPESTATUS[0]}"
  else
    echo "build exit: 0"
  fi
  echo "== emitted binaries (arch + link status) =="
  # A produced Mach-O executable inherently has 0 UNRESOLVED symbols (ld64 errors otherwise); the
  # MH_NOUNDEFS flag (file: <NOUNDEF>) confirms it. nm -u counts dyld imports (libc++/system dylibs),
  # which is expected and non-zero -- NOT link errors.
  for b in headless-shot WebContent RequestServer ImageDecoder WebWorker; do
    p=$(find "$BUILD" -maxdepth 4 -type f -name "$b" 2>/dev/null | head -1)
    if [ -n "$p" ]; then
      fl=$(file -b "$p")
      noundef=$(echo "$fl" | grep -o NOUNDEF || echo "-")
      echo "$b: $(echo "$fl" | cut -c1-40) | $noundef | dyld-imports=$("$SHIM/nm" -u "$p" 2>/dev/null | wc -l | tr -d ' ')"
    else
      echo "$b: NOT BUILT"
    fi
  done
fi

# ================================================================================================
step "STAGE package: iphoneos-arm64 deb (bin/headless-shot + libexec helpers + share/Lagom)"
# ================================================================================================
# Layout matches the compiled-in non-macOS helper search (Utilities.cpp find_prefix):
#   driver at $prefix/bin -> find_prefix -> $prefix ; helpers at $prefix/libexec + $prefix/bin ;
#   resources at $prefix/share/Lagom. $prefix = /var/jb/usr. libexec_path compiles to plain "libexec"
#   (LADYBIRD_LIBEXECDIR is only set on !APPLE; our cross is APPLE), so helpers -> $prefix/libexec.
LDID=/root/cctools/bin/ldid
VER="0.1.0+ios1"
DEB=/out/ladybird-headless_${VER}_iphoneos-arm64.deb
if run_stage package; then
  HS=$(find "$BUILD" -maxdepth 4 -type f -name headless-shot 2>/dev/null | head -1)
  if [ -z "$HS" ]; then echo "!! headless-shot not built; skipping package"; else
    PKG=/tmp/lbpkg; rm -rf "$PKG"
    mkdir -p "$PKG/DEBIAN" "$PKG/var/jb/usr/bin" "$PKG/var/jb/usr/libexec" "$PKG/var/jb/usr/share/Lagom"

    # entitlements: minimal fakesigned multiprocess set + /var/jb path-exception (no IOSurface/GPU
    # user-client at headless M0).
    ENT=/tmp/ladybird-headless-ent.xml
    cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>platform-application</key><true/>
    <key>com.apple.private.security.no-container</key><true/>
    <key>com.apple.private.amfi.can-allow-non-platform</key><true/>
    <key>com.apple.private.skip-library-validation</key><true/>
    <key>com.apple.security.exception.files.absolute-path.read-write</key>
    <array>
        <string>/var/jb/</string>
        <string>/tmp/</string>
        <string>/var/</string>
        <string>/private/var/</string>
    </array>
</dict>
</plist>
PLIST

    sign() { "$LDID" -S"$ENT" "$1" 2>/dev/null || "$LDID" -S "$1"; }

    cp "$HS" "$PKG/var/jb/usr/bin/headless-shot"; sign "$PKG/var/jb/usr/bin/headless-shot"
    for b in WebContent RequestServer ImageDecoder WebWorker; do
      p=$(find "$BUILD" -maxdepth 4 -type f -name "$b" 2>/dev/null | head -1)
      if [ -n "$p" ]; then cp "$p" "$PKG/var/jb/usr/libexec/$b"; sign "$PKG/var/jb/usr/libexec/$b"; else echo "!! helper $b missing"; fi
    done

    # resources straight from Base/res (UI's copy target is skipped on iOS).
    cp -a "$WORK"/Base/res/. "$PKG/var/jb/usr/share/Lagom/"

    INSTALLED_KB=$(du -sk "$PKG/var/jb" | cut -f1)
    cat > "$PKG/DEBIAN/control" <<EOF
Package: ladybird-headless
Name: Ladybird (headless renderer)
Version: $VER
Architecture: iphoneos-arm64
Description: Ladybird browser engine — headless PNG renderer (M0 bring-up).
 Multiprocess LibWeb engine (WebContent/RequestServer/ImageDecoder/WebWorker) with a
 headless-shot driver that loads a URL/HTML and dumps a PNG. GPU/Compositor deferred.
Section: Utilities
Maintainer: Max Leiter <maxwell.leiter@gmail.com>
Author: Ladybird contributors; iOS port by Max Leiter
Depends: libc++1, icu-ios, harfbuzz, libpng, libjpeg, libwebp7, skia
Installed-Size: $INSTALLED_KB
MinimumOSVersion: 16.0
EOF
    dpkg-deb -Zxz -b "$PKG" "$DEB" && echo "== packaged $DEB ==" && dpkg-deb -c "$DEB" | awk '{print $6}' | grep -E 'bin/|libexec/|Default.ini' | head
    ls -la "$DEB"
  fi
fi

echo; echo "########## WAVE 4b (stage=$LB_STAGE) done ##########"
