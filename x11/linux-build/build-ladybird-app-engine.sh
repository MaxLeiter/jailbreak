#!/usr/bin/env bash
# Builds the iOS Ladybird UIKit frontend + Compositor helper on procursus-vol-ladybird
# (continues wave4c state). Release builds are always real ANGLE/GPU. Set
# LB_APP_CPU_DIAGNOSTIC=1 for the intentionally non-production CPU/trap-stub build.
# Stages the resulting binaries into /out/app-stage for the .app deb driver.
#
#   docker run --rm --platform linux/arm64 \
#     -v procursus-vol-ladybird:/work/Procursus \
#     -v "$PWD/build-ladybird-app-engine.sh:/work/build-ladybird-app-engine.sh:ro" \
#     -v "$PWD/recipes-ladybird:/work/recipes-ladybird:ro" \
#     -v "$PWD/../packages/ladybird-app:/work/ladybird-app:ro" \
#     -v "$PWD/out:/out" \
#     procursus-xbuild:skia -c /work/build-ladybird-app-engine.sh
set -uo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
PROC=/work/Procursus
SDK="/root/cctools/SDK/iPhoneOS16.5.sdk"
BB=$PROC/build_base/$XIOS_TRIPLE$XIOS_PREFIX
SHIM=/work/shim
WORK=$PROC/ladybird-src
BUILD=$PROC/ladybird-build            # reuse the headless build dir; app-mode deltas recompile incrementally
HOST=$PROC/ladybird-hosttools
export RUSTUP_HOME=$PROC/build_tools/rustup
export CARGO_HOME=$PROC/build_tools/cargo
export PATH=$CARGO_HOME/bin:$PATH
export LB_APP_BUILD=1
case "${LB_APP_CPU_DIAGNOSTIC:-0}" in
  1|yes|true|on|YES|TRUE|ON)
    APP_GPU_ENABLED=0
    export LB_APP_CPU_DIAGNOSTIC=1
    # Compatibility for already-patched persistent Ladybird worktrees. Fresh
    # source patches key directly on LB_APP_CPU_DIAGNOSTIC.
    export LB_APP_GPU=0
    echo "!! LADYBIRD DIAGNOSTIC CPU BUILD: generated ANGLE trap stubs enabled; not releasable" >&2
    ;;
  *)
    APP_GPU_ENABLED=1
    export LB_APP_CPU_DIAGNOSTIC=0
    export LB_APP_GPU=1
    ;;
esac
step() { echo; echo "########## $* ##########"; }
cd "$PROC"
NM=/root/cctools/bin/aarch64-apple-darwin-nm

# ---- shim + fake xcrun/sw_vers + /var/jb (idempotent, mirrors wave4c) ----------------------
step "prep: shim + $XIOS_PREFIX symlink + fake xcrun"
# The staged Procursus tree is exposed at its device-absolute path so .pc files,
# CMake configs and -I flags resolve the same way they will on device. Rootful
# would have to stage /usr, which is the container's own Debian userland, so it
# needs a --sysroot pass rather than this symlink.
xios_require_rootless "the engine build stages the device prefix as a container symlink"
if [ ! -e "$XIOS_PREFIX" ]; then ln -s "$BB" "$XIOS_PREFIX"; fi
mkdir -p "$SHIM"
for t in ld ranlib libtool install_name_tool otool nm strip lipo dsymutil codesign_allocate \
         segedit size nmedit ar; do
  [ -e /root/cctools/bin/aarch64-apple-darwin-$t ] && ln -sf /root/cctools/bin/aarch64-apple-darwin-$t "$SHIM/$t"
done
# ar wrapper: expand @response-files, then call llvm-ar in Darwin/Mach-O format.
# The image's cctools aarch64-apple-darwin-ar is clobbered into a self-exec loop;
# llvm-ar-19 --format=darwin produces a Mach-O archive cctools ld64/ranlib accept.
cat > "$SHIM/ar" <<'EOF'
#!/bin/sh
n=$#; i=0
while [ "$i" -lt "$n" ]; do
  a=$1; shift
  case "$a" in
    @*) f="${a#@}"; for o in $(cat "$f"); do set -- "$@" "$o"; done ;;
    *)  set -- "$@" "$a" ;;
  esac
  i=$((i+1))
done
exec llvm-ar-19 --format=darwin "$@"
EOF
chmod +x "$SHIM/ar"
# Repair the clobbered cctools ar in-place too, so any direct invocation is sane.
cp -f "$SHIM/ar" /root/cctools/bin/aarch64-apple-darwin-ar 2>/dev/null || true
cat > "$SHIM/lb-cc" <<EOF
#!/bin/sh
exec clang-19 --target=arm64-apple-ios16.0 -isysroot $SDK -B$SHIM -fuse-ld=$SHIM/ld -D__IOS__ "\$@" -Wno-error
EOF
cat > "$SHIM/lb-cxx" <<EOF
#!/bin/sh
exec clang++-19 --target=arm64-apple-ios16.0 -isysroot $SDK -stdlib=libc++ -B$SHIM -fuse-ld=$SHIM/ld -D__IOS__ "\$@" -Wno-error
EOF
chmod +x "$SHIM/lb-cc" "$SHIM/lb-cxx"
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
chmod +x "$SHIM/xcrun" "$SHIM/sw_vers"
ln -sf "$SHIM/xcrun" /usr/local/bin/xcrun
ln -sf "$SHIM/sw_vers" /usr/local/bin/sw_vers

# The 16.5 SDK os/object.h predates OS_OBJECT_DECL_SENDABLE_*, but xpc/session.h (pulled in
# transitively by any UIKit->Foundation include in the frontend .mm files) needs them, so ObjC++
# compiles fail. Backport the 3 macros as aliases to their non-sendable forms. Same fix as
# build-wayland-apps.sh.
OSOBJ="$SDK/usr/include/os/object.h"
if [ -f "$OSOBJ" ] && ! grep -q OS_OBJECT_DECL_SENDABLE_CLASS "$OSOBJ"; then
  echo "==> backporting OS_OBJECT_DECL_SENDABLE_* into $OSOBJ"
  cat >> "$OSOBJ" <<'EOF'

/* XIOS: backport OS_OBJECT_DECL_SENDABLE_* (this 16.5 SDK os/object.h predates them, but its
 * newer xpc/session.h requires them; alias to the non-sendable forms — identical C/ObjC path). */
#ifndef OS_OBJECT_DECL_SENDABLE_CLASS
#define OS_OBJECT_DECL_SENDABLE_CLASS(name) OS_OBJECT_DECL_CLASS(name)
#endif
#ifndef OS_OBJECT_DECL_SENDABLE_SWIFT
#define OS_OBJECT_DECL_SENDABLE_SWIFT(name) OS_OBJECT_DECL_SWIFT(name)
#endif
#ifndef OS_OBJECT_DECL_SENDABLE_SUBCLASS_SWIFT
#define OS_OBJECT_DECL_SENDABLE_SUBCLASS_SWIFT(name, super) OS_OBJECT_DECL_SUBCLASS_SWIFT(name, super)
#endif
EOF
fi

# ---- stage the UIKit frontend into the tree ------------------------------------------------
step "stage UI/iOS frontend into ladybird-src"
mkdir -p "$WORK/UI/iOS/Sources"
cp -v /work/ladybird-app/Sources/*.h  "$WORK/UI/iOS/Sources/" 2>/dev/null || true
cp -v /work/ladybird-app/Sources/*.mm "$WORK/UI/iOS/Sources/"
cp -v /work/ladybird-app/Sources/*.cpp "$WORK/UI/iOS/Sources/"
cp -v /work/ladybird-app/CMakeLists.txt "$WORK/UI/iOS/CMakeLists.txt"

# ---- apply patches (including app-mode series; LB_APP_BUILD=1 exported) ---------------------
step "apply M0 patches + app-mode patch series"
bash /work/recipes-ladybird/ladybird-m0-patches.sh "$WORK" || exit $?
SKIA_PC=$BB/usr/lib/pkgconfig/skia.pc
if [ -f "$SKIA_PC" ] && grep -q -- '-framework CoreFoundation -framework' "$SKIA_PC"; then
  sed -i 's/-framework \([A-Za-z0-9_]*\)/-Wl,-framework,\1/g' "$SKIA_PC"
fi

# ---- complete ANGLE gl2ext_angle.h (Compositor WebGL replayer) -----------------------------
# Staged gl2ext_angle.h is missing GL_ANGLE_robust_client_memory prototypes that generated
# WebGL/GLFunctions.cpp references (needed at compile time even for diagnostic CPU builds).
# Swap in the complete header from the ANGLE checkout.
BB_ANGLE=$BB/usr/include/GLES2/gl2ext_angle.h
if [ -f "$BB_ANGLE" ] && ! grep -q glCompressedTexImage2DRobustANGLE "$BB_ANGLE"; then
  FULL_ANGLE=$(find "$PROC/build_work" -path "*angle/checkout/include/GLES2/gl2ext_angle.h" 2>/dev/null | head -1)
  if [ -n "$FULL_ANGLE" ] && grep -q glCompressedTexImage2DRobustANGLE "$FULL_ANGLE"; then
    cp "$FULL_ANGLE" "$BB_ANGLE"
    echo "  [driver] replaced gl2ext_angle.h with complete ANGLE header ($FULL_ANGLE)"
  else
    echo "  [driver] WARN: no complete gl2ext_angle.h found; WebGL GLFunctions.cpp may fail"
  fi
fi

# ---- ANGLE runtime for the app GPU build ----------------------------------------------------
# Mixing ANGLE libEGL with Mesa GLES (also present in build_base) gives a "current" context whose
# gl* entry points return null/zero objects, so ANGLE EGL must pair with ANGLE GLES. Stage the
# real ANGLE payload and put a higher-priority pkg-config overlay in front of build_base's .pc files.
ANGLE_PC_DIR=$PROC/ladybird-angle-pkgconfig
if [ "$APP_GPU_ENABLED" -eq 1 ]; then
  step "stage ANGLE EGL/GLES runtime for GPU build"
  ANGLE_DIR=$BB/lib/angle
  mkdir -p "$ANGLE_DIR"
  if [ ! -f "$ANGLE_DIR/libGLESv2.dylib" ] || [ ! -f "$ANGLE_DIR/libEGL.angle.dylib" ]; then
    ANGLE_DEB=$(ls -1 /out/angle_*_$XIOS_DEB_ARCH.deb 2>/dev/null | sort | tail -1 || true)
    if [ -z "$ANGLE_DEB" ]; then
      echo "!! release Ladybird builds need /out/angle_*_$XIOS_DEB_ARCH.deb to stage real ANGLE GLES" >&2
      exit 2
    fi
    TMPANGLE=$(mktemp -d)
    dpkg-deb -x "$ANGLE_DEB" "$TMPANGLE" || exit $?
    cp -a "$TMPANGLE$XIOS_PREFIX/lib/angle/." "$ANGLE_DIR/"
    rm -rf "$TMPANGLE"
    echo "  staged ANGLE runtime from $ANGLE_DEB"
  fi

  mkdir -p "$ANGLE_PC_DIR"
  cat > "$ANGLE_PC_DIR/egl.pc" <<EOF
prefix=$XIOS_PREFIX
libdir=\${prefix}/lib/angle
includedir=\${prefix}/usr/include

Name: EGL
Description: ANGLE EGL (Metal) for the Ladybird iOS app
Version: 1.5
Libs: \${libdir}/libEGL.angle.dylib
Cflags: -I\${includedir}
EOF
  cat > "$ANGLE_PC_DIR/glesv2.pc" <<EOF
prefix=$XIOS_PREFIX
libdir=\${prefix}/lib/angle
includedir=\${prefix}/usr/include

Name: glesv2
Description: ANGLE OpenGL ES 2/3 over Metal for the Ladybird iOS app
Version: 2.1
Libs: \${libdir}/libGLESv2.dylib
Cflags: -I\${includedir}
EOF
fi

# ---- configure ------------------------------------------------------------------------------
step "configure (separate app build dir)"
export LB_STAGED_PREFIX=$XIOS_PREFIX
PKG_CONFIG_DIRS=$XIOS_PREFIX/usr/lib/pkgconfig:$XIOS_PREFIX/usr/share/pkgconfig
if [ "$APP_GPU_ENABLED" -eq 1 ]; then
  PKG_CONFIG_DIRS="$ANGLE_PC_DIR:$PKG_CONFIG_DIRS"
fi
export PKG_CONFIG_PATH="$PKG_CONFIG_DIRS"
export PKG_CONFIG_LIBDIR="$PKG_CONFIG_DIRS"
export LB_SHIM="$SHIM"
export LB_HOST_GEN_ASM_OFFSETS="$HOST/gen_asm_offsets"
export LB_HOST_ASMINTGEN="$HOST/asmintgen"
CMAKE_UNSET_ARGS=()
if [ "$APP_GPU_ENABLED" -eq 1 ]; then
  CMAKE_UNSET_ARGS=(-UEGL_* -UGLESv2_*)
fi
cd "$WORK"
# reuse ladybird-build's CMakeCache (incremental); cmake re-run picks up the new UI/iOS + Compositor
CONFIG_LOG=/out/ladybird-app-configure.log
cmake "${CMAKE_UNSET_ARGS[@]}" -GNinja -B "$BUILD" -S "$WORK" \
  -DCMAKE_TOOLCHAIN_FILE=/work/recipes-ladybird/ios-toolchain.cmake \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DENABLE_GUI_TARGETS=ON \
  -DENABLE_INSTALL_HEADERS=OFF -DENABLE_NETWORK_DOWNLOADS=ON -DENABLE_CLANG_PLUGINS=OFF \
  -DENABLE_CRANELIFT_JIT=OFF -DRUST_TARGET_TRIPLE=aarch64-apple-ios \
  -DLADYBIRD_CACHE_DIR="${XIOS_PREFIX:-/var}/lib/ladybird" -DVCPKG_ROOT= 2>&1 | tee "$CONFIG_LOG" | tail -20
cfg=${PIPESTATUS[0]}
echo "configure exit: $cfg"
if [ "$cfg" -ne 0 ]; then
  echo "---- configure failure context ($CONFIG_LOG) ----" >&2
  tail -100 "$CONFIG_LOG" >&2
  exit "$cfg"
fi
cd "$BUILD"

# ---- Compositor EGL/GLES link path ---------------------------------------------------------
if [ "$APP_GPU_ENABLED" -eq 1 ]; then
  step "Compositor: build service lib with real EGL/GLES"
else
  step "Compositor: DIAGNOSTIC CPU build + generated egl/gl trap stubs"
fi
ninja -k 0 -j"$(nproc)" compositorservice 2>&1 | tail -8
CS=$(find "$BUILD" -name libcompositorservice.a | head -1)
STUBSRC="$WORK/Services/Compositor/AngleStubIOS.cpp"
if [ "$APP_GPU_ENABLED" -eq 0 ] && [ -n "$CS" ] && [ -f "$STUBSRC" ]; then
  # undefined egl/gl/EGL symbols across the whole service archive
  SYMS=$("$NM" -u "$CS" 2>/dev/null | sed 's/^ *//' | grep -Eo '_(egl|gl|EGL)[A-Za-z0-9_]*' | sort -u | sed 's/^_//')
  echo "undefined ANGLE symbols: $(echo "$SYMS" | wc -w)"
  if [ -n "$SYMS" ]; then
    GEN=$(for s in $SYMS; do echo "void $s(void) { __builtin_trap(); }"; done)
    python3 - "$STUBSRC" <<PY
import sys
p=sys.argv[1]; s=open(p).read()
b="// __LB_ANGLE_STUBS_BEGIN__"; e="// __LB_ANGLE_STUBS_END__"
gen='''$GEN'''
s=s[:s.index(b)+len(b)]+"\n"+gen+"\n"+s[s.index(e):]
open(p,"w").write(s)
print("  filled", gen.count(";"), "stub symbols")
PY
    ninja -k 0 -j"$(nproc)" compositorservice 2>&1 | tail -4
  fi
fi

# ---- build everything -----------------------------------------------------------------------
step "build: helpers + Compositor + Ladybird UI"
TARGETS="WebContent RequestServer ImageDecoder WebWorker Compositor Ladybird"
ninja -k 0 -j"$(nproc)" $TARGETS 2>&1 | tee /out/app-engine-build.log | tail -40
p1=${PIPESTATUS[0]}
if [ "$p1" -ne 0 ]; then
  echo "== pass1 exit $p1; -j2 retry (OOM giants / late undefined stubs) =="
  # second stub harvest from the link log (catches symbols only pulled by the final exe link)
  MORE=
  if [ "$APP_GPU_ENABLED" -eq 0 ]; then
    MORE=$(grep -Eo '"_(egl|gl|EGL)[A-Za-z0-9_]*"' /out/app-engine-build.log | tr -d '"' | sort -u | sed 's/^_//')
  fi
  if [ -n "$MORE" ] && [ -f "$STUBSRC" ]; then
    HAVE=$(grep -Eo 'void [A-Za-z0-9_]+\(void\)' "$STUBSRC" | awk '{print $2}' | sed 's/(void)//')
    ADD=$(comm -23 <(echo "$MORE"|sort -u) <(echo "$HAVE"|sort -u))
    if [ -n "$ADD" ]; then
      GEN=$(for s in $ADD; do echo "void $s(void) { __builtin_trap(); }"; done)
      python3 - "$STUBSRC" <<PY
import sys
p=sys.argv[1]; s=open(p).read()
e="// __LB_ANGLE_STUBS_END__"
s=s[:s.index(e)]+'''$GEN'''+"\n"+s[s.index(e):]
open(p,"w").write(s); print("  added late stubs")
PY
      ninja -k 0 -j"$(nproc)" compositorservice 2>&1 | tail -3
    fi
  fi
  ninja -k 0 -j2 $TARGETS 2>&1 | tee -a /out/app-engine-build.log | tail -30
  p2=${PIPESTATUS[0]}
  echo "build exit (pass2): $p2"
  [ "$p2" -eq 0 ] || exit "$p2"
else
  echo "build exit: 0"
fi

# ---- report emitted binaries ----------------------------------------------------------------
step "emitted binaries"
STAGE=/out/app-stage; rm -rf "$STAGE"; mkdir -p "$STAGE/share"
for b in Ladybird WebContent RequestServer ImageDecoder WebWorker Compositor; do
  p=$(find "$BUILD" -maxdepth 4 -type f -name "$b" 2>/dev/null | head -1)
  if [ -n "$p" ]; then
    echo "$b: $(file -b "$p" | cut -c1-40) | $(file -b "$p" | grep -o NOUNDEF || echo 'HAS-UNDEF')"
    cp "$p" "$STAGE/$b"
  else echo "$b: NOT BUILT"; fi
done
if [ -d "$WORK/Base/res" ]; then cp -a "$WORK/Base/res/." "$STAGE/share/Lagom/" 2>/dev/null || mkdir -p "$STAGE/share/Lagom" && cp -a "$WORK/Base/res/." "$STAGE/share/Lagom/"; fi
echo "staged -> $STAGE"; ls -la "$STAGE"
echo; echo "########## APP ENGINE BUILD done ##########"
