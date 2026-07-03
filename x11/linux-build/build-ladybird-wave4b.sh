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
for t in ld ar ranlib libtool install_name_tool otool nm strip lipo dsymutil codesign_allocate \
         segedit size nmedit; do
  [ -e /root/cctools/bin/aarch64-apple-darwin-$t ] && ln -sf /root/cctools/bin/aarch64-apple-darwin-$t "$SHIM/$t"
done
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

if run_stage hosttools; then
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
  # reconfigure in place: patch 12 changed LibJS/CMakeLists.txt and LB_HOST_* are now exported, so
  # cmake regenerates build.ninja with the host-tool custom commands. Existing objects are kept.
  cmake -GNinja -B "$BUILD" -S "$WORK" \
    -DCMAKE_TOOLCHAIN_FILE=/work/recipes-ladybird/ios-toolchain.cmake \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DENABLE_GUI_TARGETS=ON \
    -DENABLE_INSTALL_HEADERS=OFF -DENABLE_NETWORK_DOWNLOADS=ON -DENABLE_CLANG_PLUGINS=OFF \
    -DENABLE_CRANELIFT_JIT=OFF -DRUST_TARGET_TRIPLE=aarch64-apple-ios \
    -DLADYBIRD_CACHE_DIR=/var/jb/lib/ladybird -DVCPKG_ROOT= 2>&1 | tail -6
  echo "reconfigure exit: ${PIPESTATUS[0]}"

  cd "$BUILD"
  ninja -k 0 -j"$(nproc)" WebContent RequestServer ImageDecoder WebWorker \
    2>&1 | tee /out/wave4b-build.log
  echo "build exit: ${PIPESTATUS[0]}"
  echo "== emitted helper binaries =="
  for b in WebContent RequestServer ImageDecoder WebWorker; do
    p=$(find "$BUILD" -maxdepth 4 -type f -name "$b" 2>/dev/null | head -1)
    [ -n "$p" ] && echo "$b: $(file -b "$p" | cut -c1-45) | undef=$("$SHIM/nm" -u "$p" 2>/dev/null | wc -l)"
  done
fi

echo; echo "########## WAVE 4b (stage=$LB_STAGE) done ##########"
