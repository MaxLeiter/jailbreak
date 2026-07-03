#!/usr/bin/env bash
# Wave 4 — configure + cross-build LADYBIRD itself (headless renderer + helper processes) for
# iphoneos-arm64, against the Waves 1-3 + Skia + ICU closure staged on procursus-vol-ladybird.
#
#   docker run --rm --platform linux/arm64 \
#     -v procursus-vol-ladybird:/work/Procursus \
#     -v "$PWD/build-ladybird-wave4.sh:/work/build-ladybird-wave4.sh:ro" \
#     -v "$PWD/recipes-ladybird:/work/recipes-ladybird:ro" \
#     -v "$PWD/out:/out" \
#     procursus-xbuild:skia -c /work/build-ladybird-wave4.sh
#
# Toolchain: clang-19 (C++23) + cctools ld64/libtool + iPhoneOS16.5.sdk libc++ (proven to link a
# C++23 Mach-O arm64 exe). CMake cross via CMAKE_SYSTEM_NAME=Darwin + fake xcrun + forced IOS=TRUE
# (recipes-ladybird/ios-toolchain.cmake). All Ladybird codegen is Python now (no host-tool cross
# split). Rust: 8 core libs build staticlib crates -> rustup toolchain 1.96.0 + aarch64-apple-ios.
#
# Stages (LB_STAGE, default "all"): prep | deps | fetch | configure | build | all
set -uo pipefail

LADYBIRD_REF="${LADYBIRD_REF:-92b0257e71bb7a80a3106f2365bacdfa09f6c0f7}"   # main @ 2026-07-02 (recon tree)
LB_STAGE="${LB_STAGE:-all}"
SDK=/root/cctools/SDK/iPhoneOS16.5.sdk
PROC=/work/Procursus
BB=$PROC/build_base/iphoneos-arm64-rootless/1900/var/jb
SHIM=/work/shim
WORK=$PROC/ladybird-src
BUILD=$PROC/ladybird-build
export RUSTUP_HOME=$PROC/build_tools/rustup
export CARGO_HOME=$PROC/build_tools/cargo
# NOTE: $SHIM is deliberately NOT on PATH. Its cctools mach-o tools (unprefixed ld/ar/libtool)
# would shadow the host GNU toolchain that cargo needs to build+link HOST build.rs/proc-macros
# (aarch64-unknown-linux-gnu) -> cctools ld64 chokes on GNU ld's -plugin. All shim tools are
# referenced by ABSOLUTE path (toolchain CMAKE_AR/etc + lb-cc/lb-cxx -B$SHIM -fuse-ld=$SHIM/ld).
# Only xcrun/sw_vers must be found by name (CMake Darwin probe) -> placed in /usr/local/bin.
export PATH=$CARGO_HOME/bin:$PATH
mkdir -p /out

step() { echo; echo "########## $* ##########"; }
run_stage() { case "$LB_STAGE" in all) return 0;; "$1") return 0;; *) return 1;; esac; }

# ================================================================================================
step "STAGE prep: /var/jb symlink, shim toolchain, fake xcrun, rustup"
# ================================================================================================
# Expose the staged Procursus tree at its device-absolute path so .pc / CMake-config / -I/var/jb
# resolve on the host.
if [ ! -e /var/jb ]; then ln -s "$BB" /var/jb; fi
ls -ld /var/jb; echo "/var/jb -> $(readlink -f /var/jb)"

mkdir -p "$SHIM"
# unprefixed cctools mach-o tools
for t in ld ar ranlib libtool install_name_tool otool nm strip lipo dsymutil codesign_allocate \
         lipo segedit size nmedit; do
  [ -e /root/cctools/bin/aarch64-apple-darwin-$t ] && ln -sf /root/cctools/bin/aarch64-apple-darwin-$t "$SHIM/$t"
done
# clang-19 compiler wrappers: Apple/iOS target + cctools ld64. -D__IOS__ sets AK_OS_IOS.
# -Wno-error is appended AFTER "$@" so it beats Ladybird's per-target -Werror (which appears earlier
# on the command line via target_compile_options); clang honors the last -W flag.
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
# fake xcrun / sw_vers so CMake's Darwin platform probe is satisfied off-Mac.
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
# xcrun/sw_vers must be resolvable by name for CMake's Darwin platform probe; expose ONLY these
# two on PATH (via /usr/local/bin) so the cctools mach-o tools never shadow the host GNU toolchain.
ln -sf "$SHIM/xcrun" /usr/local/bin/xcrun
ln -sf "$SHIM/sw_vers" /usr/local/bin/sw_vers
echo "shim tools:"; ls "$SHIM"

# rustup toolchain 1.96.0 (pinned by rust-toolchain.toml) + aarch64-apple-ios target, persisted on
# the volume so re-runs skip the download.
if ! command -v rustc >/dev/null 2>&1; then
  echo "==> installing rustup (persisted on volume)"
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain 1.96.0 --profile minimal --no-modify-path 2>&1 | tail -3
fi
"$CARGO_HOME/bin/rustup" toolchain install 1.96.0 --profile minimal 2>&1 | tail -1 || true
"$CARGO_HOME/bin/rustup" target add --toolchain 1.96.0 aarch64-apple-ios 2>&1 | tail -1 || true
"$CARGO_HOME/bin/rustc" --version || echo "!! rustc missing"

run_stage prep && [ "$LB_STAGE" = prep ] && { echo "prep done"; exit 0; }

# ================================================================================================
step "STAGE deps: reconcile libxml2 shadow; stage Skia + ANGLE headers + SDL3 stub into /var/jb"
# ================================================================================================
if run_stage deps; then
  # --- libxml2 2.9.12 shadow -> 2.13.8 (the known gap) ---
  echo "==> libxml2: wiping 2.9.12 shadow, staging 2.13.8 from /out deb"
  rm -rf $BB/usr/lib/libxml2.* $BB/usr/include/libxml2 $BB/usr/lib/pkgconfig/libxml-2.0.pc \
         $BB/usr/lib/cmake/libxml2*
  rm -rf /tmp/xmlstage; mkdir -p /tmp/xmlstage
  for d in /out/libxml2_2.13.8*_iphoneos-arm64.deb /out/libxml2-dev_2.13.8*_iphoneos-arm64.deb; do
    [ -f "$d" ] && { echo "  extracting $(basename "$d")"; dpkg-deb -x "$d" /tmp/xmlstage; }
  done
  # deb layout is ./var/jb/... -> copy the var/jb subtree into build_base's var/jb
  [ -d /tmp/xmlstage/var/jb ] && cp -a /tmp/xmlstage/var/jb/. "$BB/"
  rm -rf /tmp/xmlstage
  echo "  libxml-2.0.pc version now: $(grep -h ^Version $BB/usr/lib/pkgconfig/libxml-2.0.pc 2>/dev/null)"

  # --- wuffs header path: our recipe staged /usr/include/wuffs-v0.3.c but Ladybird's
  #     find_path wants wuffs/wuffs-v0.3.c (a wuffs/ subdir). Mirror it. ---
  if [ -f $BB/usr/include/wuffs-v0.3.c ] && [ ! -f $BB/usr/include/wuffs/wuffs-v0.3.c ]; then
    mkdir -p $BB/usr/include/wuffs
    cp -a $BB/usr/include/wuffs-v0.3.c $BB/usr/include/wuffs/wuffs-v0.3.c
    echo "==> mirrored wuffs header into wuffs/ subdir"
  fi

  # --- Skia (built at /out/skia-ios-arm64) into /var/jb ---
  echo "==> staging Skia (libskia.a, libskcms.a, headers, skia.pc)"
  if [ -d /out/skia-ios-arm64 ]; then
    cp -a /out/skia-ios-arm64/lib/libskia.a /out/skia-ios-arm64/lib/libskcms.a $BB/usr/lib/ 2>/dev/null || \
      cp -a /out/skia-ios-arm64/lib/*.a $BB/usr/lib/
    # /out/skia-ios-arm64/include/ contains a skia/ subdir whose children are core/, gpu/, ... .
    # Ladybird includes <core/SkCanvas.h> against includedir=/var/jb/include/skia, so the core/ dir
    # must land directly under /var/jb/include/skia (copy the INNER skia/. , not include/. , else
    # it double-nests to include/skia/skia/core).
    rm -rf $BB/include/skia; mkdir -p $BB/include/skia
    if [ -d /out/skia-ios-arm64/include/skia ]; then
      cp -a /out/skia-ios-arm64/include/skia/. $BB/include/skia/
    else
      cp -a /out/skia-ios-arm64/include/. $BB/include/skia/
    fi
    mkdir -p $BB/usr/lib/pkgconfig
    cp -a /out/skia-ios-arm64/lib/pkgconfig/skia.pc $BB/usr/lib/pkgconfig/skia.pc
    echo "  skia.pc: $(grep -h ^Version $BB/usr/lib/pkgconfig/skia.pc)"
  else
    echo "  !! /out/skia-ios-arm64 missing"
  fi

  # --- ANGLE GLES/EGL headers (LibWeb includes them for WebGL constants; NO link on WebContent) ---
  echo "==> staging ANGLE headers + angle.pc (headers-only)"
  if [ ! -f $BB/usr/include/GLES2/gl2ext_angle.h ]; then
    rm -rf /tmp/angle
    git clone --depth 1 --filter=blob:none --sparse https://chromium.googlesource.com/angle/angle /tmp/angle 2>&1 | tail -2 \
      && ( cd /tmp/angle && git sparse-checkout set include 2>&1 | tail -1 )
    if [ -d /tmp/angle/include ]; then
      cp -a /tmp/angle/include/. $BB/usr/include/
      echo "  staged ANGLE headers: $(ls $BB/usr/include/GLES2 2>/dev/null | head -3 | tr '\n' ' ')"
    else
      echo "  !! ANGLE include/ fetch failed"
    fi
  fi
  cat > $BB/usr/lib/pkgconfig/angle.pc <<'EOF'
prefix=/var/jb
includedir=${prefix}/usr/include
Name: angle
Description: ANGLE GLES/EGL headers (M0 headers-only; GL entry points live in Compositor)
Version: 7258
Cflags: -I${includedir}
Libs:
EOF

  # --- SDL3 stub: real 3.2.x headers + no-op static lib + SDL3Config.cmake (gamepad never fires
  #     in a headless PNG render; avoids a UIKit-pulling real SDL3 build) ---
  echo "==> staging SDL3 stub (real headers + no-op lib + config)"
  if [ ! -f $BB/usr/lib/libSDL3.a ]; then
    rm -rf /tmp/sdl3
    git clone --depth 1 --branch release-3.2.28 https://github.com/libsdl-org/SDL /tmp/sdl3 2>&1 | tail -2 || \
      git clone --depth 1 https://github.com/libsdl-org/SDL /tmp/sdl3 2>&1 | tail -2
    if [ -d /tmp/sdl3/include/SDL3 ]; then
      mkdir -p $BB/usr/include/SDL3
      cp -a /tmp/sdl3/include/SDL3/. $BB/usr/include/SDL3/
      # generate build_version.h if template-only
      [ -f $BB/usr/include/SDL3/SDL_revision.h ] || echo '#define SDL_REVISION "stub"' > $BB/usr/include/SDL3/SDL_revision.h
      # no-op stub implementation of the symbols LibWeb/Gamepad + EventHandler reference
      cat > /tmp/sdl3_stub.c <<'EOF'
#include <SDL3/SDL.h>
/* M0 headless stub: no controllers ever present. */
bool SDL_PollEvent(SDL_Event *e){ (void)e; return false; }
void SDL_UpdateJoysticks(void){}
SDL_JoystickID *SDL_GetGamepads(int *count){ if(count)*count=0; return NULL; }
SDL_Gamepad *SDL_OpenGamepad(SDL_JoystickID id){ (void)id; return NULL; }
void SDL_CloseGamepad(SDL_Gamepad *g){ (void)g; }
const char *SDL_GetGamepadNameForID(SDL_JoystickID id){ (void)id; return ""; }
SDL_PropertiesID SDL_GetGamepadProperties(SDL_Gamepad *g){ (void)g; return 0; }
bool SDL_GetBooleanProperty(SDL_PropertiesID p, const char *n, bool d){ (void)p;(void)n; return d; }
bool SDL_GamepadHasButton(SDL_Gamepad *g, SDL_GamepadButton b){ (void)g;(void)b; return false; }
bool SDL_GamepadHasAxis(SDL_Gamepad *g, SDL_GamepadAxis a){ (void)g;(void)a; return false; }
bool SDL_GetGamepadButton(SDL_Gamepad *g, SDL_GamepadButton b){ (void)g;(void)b; return false; }
Sint16 SDL_GetGamepadAxis(SDL_Gamepad *g, SDL_GamepadAxis a){ (void)g;(void)a; return 0; }
bool SDL_RumbleGamepad(SDL_Gamepad *g, Uint16 l, Uint16 h, Uint32 ms){ (void)g;(void)l;(void)h;(void)ms; return false; }
bool SDL_RumbleGamepadTriggers(SDL_Gamepad *g, Uint16 l, Uint16 r, Uint32 ms){ (void)g;(void)l;(void)r;(void)ms; return false; }
Sint16 SDL_GetJoystickAxis(SDL_Joystick *j, int a){ (void)j;(void)a; return 0; }
bool SDL_IsJoystickVirtual(SDL_JoystickID id){ (void)id; return false; }
const char *SDL_GetError(void){ return ""; }
void SDL_free(void *p){ (void)p; }
EOF
      "$SHIM/lb-cc" -std=c11 -I$BB/usr/include -c /tmp/sdl3_stub.c -o /tmp/sdl3_stub.o \
        && "$SHIM/libtool" -static -o $BB/usr/lib/libSDL3.a /tmp/sdl3_stub.o \
        && echo "  built libSDL3.a stub" || echo "  !! SDL3 stub build FAILED (see errors above)"
      mkdir -p $BB/usr/lib/cmake/SDL3
      cat > $BB/usr/lib/cmake/SDL3/SDL3Config.cmake <<'EOF'
# M0 stub SDL3 config: header-accurate, no-op lib. Satisfies find_package(SDL3 CONFIG REQUIRED).
add_library(SDL3::SDL3 STATIC IMPORTED)
set_target_properties(SDL3::SDL3 PROPERTIES
  IMPORTED_LOCATION "/var/jb/usr/lib/libSDL3.a"
  INTERFACE_INCLUDE_DIRECTORIES "/var/jb/usr/include")
set(SDL3_FOUND TRUE)
EOF
      cat > $BB/usr/lib/cmake/SDL3/SDL3ConfigVersion.cmake <<'EOF'
set(PACKAGE_VERSION "3.2.28")
set(PACKAGE_VERSION_COMPATIBLE TRUE)
set(PACKAGE_VERSION_EXACT TRUE)
EOF
    else
      echo "  !! SDL3 header fetch failed"
    fi
  fi
fi

# ================================================================================================
step "STAGE fetch: clone Ladybird @ $LADYBIRD_REF and apply M0 patches"
# ================================================================================================
if run_stage fetch; then
  if [ ! -d "$WORK/.git" ]; then
    rm -rf "$WORK"
    git clone https://github.com/LadybirdBrowser/ladybird.git "$WORK" 2>&1 | tail -3
  fi
  ( cd "$WORK" && git fetch --depth 200 origin "$LADYBIRD_REF" 2>/dev/null; git checkout -f "$LADYBIRD_REF" 2>&1 | tail -1 || git checkout -f main 2>&1 | tail -1 )
  echo "Ladybird HEAD: $(cd "$WORK" && git log -1 --format='%h %ci')"
  bash /work/recipes-ladybird/ladybird-m0-patches.sh "$WORK"
fi

# ================================================================================================
step "STAGE configure: cmake with the iOS toolchain (no vcpkg)"
# ================================================================================================
export LB_SHIM="$SHIM"
export LB_STAGED_PREFIX=/var/jb
export PKG_CONFIG_PATH=/var/jb/usr/lib/pkgconfig:/var/jb/usr/share/pkgconfig
export PKG_CONFIG_LIBDIR=/var/jb/usr/lib/pkgconfig:/var/jb/usr/share/pkgconfig
if run_stage configure; then
  rm -rf "$BUILD"; mkdir -p "$BUILD"
  cd "$WORK"
  cmake -GNinja -B "$BUILD" -S "$WORK" \
    -DCMAKE_TOOLCHAIN_FILE=/work/recipes-ladybird/ios-toolchain.cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DENABLE_GUI_TARGETS=ON \
    -DENABLE_INSTALL_HEADERS=OFF \
    -DENABLE_NETWORK_DOWNLOADS=ON \
    -DENABLE_CLANG_PLUGINS=OFF \
    -DENABLE_CRANELIFT_JIT=OFF \
    -DRUST_TARGET_TRIPLE=aarch64-apple-ios \
    -DLADYBIRD_CACHE_DIR=/var/jb/lib/ladybird \
    -DVCPKG_ROOT= \
    2>&1 | tee /out/wave4-configure.log
  echo "configure exit: ${PIPESTATUS[0]}"
fi

# ================================================================================================
step "STAGE build: helper processes (WebContent/RequestServer/ImageDecoder/WebWorker)"
# ================================================================================================
#
# KNOWN REMAINING WALL (the sole host-tool cross split): LibJS's AsmInterpreter
# (Libraries/LibJS/CMakeLists.txt ~324-400) runs TWO build-time tools that are cross-compiled for
# iOS and therefore cannot execute on this Linux host:
#   1. gen_asm_offsets (C++, links AK)  -> runs to emit Bytecode/AsmInterpreter/asm_offsets.conf
#   2. asmintgen        (Rust binary AsmIntGen) -> runs with --arch aarch64 --object-format macho
#      --constants asm_offsets.conf --bytecode-def Bytecode.def -> asmint_aarch64.S
# This blocks LibJS -> LibWeb -> WebContent/WebWorker (build stops ~[425/2705] at asm_offsets.conf).
# FIX (native-then-cross, follow-up): build both tools for the BUILD host (host clang + host AK for
# gen_asm_offsets; `cargo build` host target for asmintgen), run them (offsets are LP64-portable
# x86_64-linux == arm64-ios; asmintgen emits aarch64 asm from the --arch flag regardless of host),
# and pre-place asm_offsets.conf + asmint_aarch64.S into the cross build dir (or patch the two
# add_custom_command COMMANDs to invoke the host binaries). Everything downstream is proven to
# compile+link (ImageDecoder + RequestServer already emit clean NOUNDEFS arm64 Mach-O).
#
if run_stage build; then
  cd "$BUILD"
  # Build codegen first (all-Python), then the helper services. -k 0 keeps going so a single run
  # enumerates the whole macOS-vs-iOS porting tail instead of one error per pass.
  ninja -k 0 -j"$(nproc)" WebContent RequestServer ImageDecoder WebWorker \
    2>&1 | tee /out/wave4-build.log
  echo "build exit: ${PIPESTATUS[0]}"
  echo "== emitted binaries =="
  find "$BUILD" -maxdepth 4 -type f \( -name WebContent -o -name RequestServer -o -name ImageDecoder -o -name WebWorker \) -exec sh -c 'echo "$1: $(file -b "$1" | cut -c1-40)"' _ {} \;
fi

echo; echo "########## WAVE 4 done (stage=$LB_STAGE) ##########"
