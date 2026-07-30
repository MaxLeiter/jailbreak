#!/usr/bin/env bash
# Wave 4c — THE PAINT FIX + A10 mimalloc, on procursus-vol-ladybird. Continues wave4b's state
# (ladybird-src patched 1-15, ladybird-build fully compiled, ladybird-hosttools present).
#
#   docker run --rm --platform linux/arm64 \
#     -v procursus-vol-ladybird:/work/Procursus \
#     -v "$PWD/build-ladybird-wave4c.sh:/work/build-ladybird-wave4c.sh:ro" \
#     -v "$PWD/recipes-ladybird:/work/recipes-ladybird:ro" \
#     -v "$PWD/build_info-ladybird:/work/build_info-ladybird:ro" \
#     -v "$PWD/out:/out" \
#     procursus-xbuild:skia -c /work/build-ladybird-wave4c.sh
#
# Does three things:
#   0) rebuild libmimalloc with -mcpu=apple-a10 (no ARMv8.1 LSE `casal` -> no A10 SIGILL); disasm-verify.
#   1) re-apply M0 patches (now incl. #16 render_screenshot iOS CPU-raster + #17 connect gate),
#      reconfigure, ninja-relink headless-shot + 4 helpers.
#   2) repackage ladybird-headless deb @ 0.1.1+ios1.
set -uo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
PROC=/work/Procursus
SDK="/root/cctools/SDK/iPhoneOS16.5.sdk"
BB=$PROC/build_base/$XIOS_TRIPLE$XIOS_PREFIX
SHIM=/work/shim   # MUST match wave4/wave4b (baked into build.ninja + the toolchain's LB_SHIM default)
WORK=$PROC/ladybird-src
BUILD=$PROC/ladybird-build
HOST=$PROC/ladybird-hosttools
export RUSTUP_HOME=$PROC/build_tools/rustup
export CARGO_HOME=$PROC/build_tools/cargo
export PATH=$CARGO_HOME/bin:$PATH
LB_STAGE="${LB_STAGE:-all}"
run_stage() { case "$LB_STAGE" in all) return 0;; "$1") return 0;; *) return 1;; esac; }
step() { echo; echo "########## $* ##########"; }
cd "$PROC"

# ================================================================================================
step "STAGE mimalloc: rebuild A10-safe (-mcpu=apple-a10, no LSE atomics)"
# ================================================================================================
if run_stage mimalloc; then
  cp -v /work/recipes-ladybird/mimalloc.mk makefiles/ >/dev/null
  cat > build_tools/cc-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
EOF
  cat > build_tools/cxx-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
EOF
  chmod +x build_tools/cc-nounused build_tools/cxx-nounused
  # force a clean rebuild: drop the keyed build tree (.build_complete guard) + stage + dist
  rm -rf build_work/$XIOS_TRIPLE/mimalloc build_stage/mimalloc \
         build_dist/libmimalloc build_dist/libmimalloc-dev
  COMMON="$XIOS_MEMO_ARGS NO_PGP=1 \
    CC=$PROC/build_tools/cc-nounused CXX=$PROC/build_tools/cxx-nounused"
  if make mimalloc-package $COMMON -j"$(nproc)" 2>&1 | tail -15; then
    echo "== mimalloc-package OK =="
  else
    echo "!! mimalloc-package FAILED"; fi
  # collect
  find . -name "libmimalloc_*_iphoneos-arm64.deb" -newermt "-30 min" -exec cp -v {} /out/ \; 2>/dev/null || true
  # LSE disassembly scan on the freshly staged/dist dylib
  MDYL=$(find build_stage/mimalloc build_dist -name "libmimalloc.*.dylib" 2>/dev/null | head -1)
  echo "== LSE scan on $MDYL =="
  if [ -n "$MDYL" ]; then
    LSE=$(/root/cctools/bin/aarch64-apple-darwin-otool -tv "$MDYL" 2>/dev/null \
      | grep -Eiwc 'casal|casa|casl|cas|caspal|casp|ldadd|ldadda|ldaddal|ldaddl|ldset|ldclr|ldeor|swp|swpa|swpal|swpl|stadd' || true)
    echo "  LSE mnemonic count = ${LSE:-?}  (want 0)"
    /root/cctools/bin/aarch64-apple-darwin-otool -tv "$MDYL" 2>/dev/null | grep -Eiw 'casal|cas|ldadd|swp|stadd' | head -5 || echo "  (no LSE mnemonics found)"
  else
    echo "  !! no staged libmimalloc dylib found"
  fi
fi

# ================================================================================================
step "STAGE prep: /var/jb symlink + shim + fake xcrun + re-apply M0 patches (idempotent)"
# ================================================================================================
if run_stage engine || run_stage package; then
  # The engine build compiles the device prefix into its binaries, and gets there
  # by making the container's own /var/jb the staged sysroot. A rootful target
  # would need /usr staged instead, which collides with the Debian userland the
  # cross toolchain runs on — so it needs a --sysroot pass, not a symlink.
  xios_require_rootless "the engine build stages the device prefix as a container symlink"
  if [ ! -e "$XIOS_PREFIX" ]; then ln -s "$BB" "$XIOS_PREFIX"; fi
  mkdir -p "$SHIM"
  for t in ld ranlib libtool install_name_tool otool nm strip lipo dsymutil codesign_allocate \
           segedit size nmedit ar; do
    [ -e /root/cctools/bin/aarch64-apple-darwin-$t ] && ln -sf /root/cctools/bin/aarch64-apple-darwin-$t "$SHIM/$t"
  done
  # ar @response-file wrapper (cctools ar can't parse @file)
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
exec /root/cctools/bin/aarch64-apple-darwin-ar "$@"
EOF
  chmod +x "$SHIM/ar"
  # lb-cc / lb-cxx: the triple-pinned clang-19 wrappers the toolchain file + build.ninja reference.
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

  step "re-applying M0 patches (adds #16 paint fix + #17 connect gate)"
  bash /work/recipes-ladybird/ladybird-m0-patches.sh "$WORK"

  # skia.pc framework-syntax fixup (idempotent)
  SKIA_PC=$BB/usr/lib/pkgconfig/skia.pc
  if [ -f "$SKIA_PC" ] && grep -q -- '-framework CoreFoundation -framework' "$SKIA_PC"; then
    sed -i 's/-framework \([A-Za-z0-9_]*\)/-Wl,-framework,\1/g' "$SKIA_PC"
  fi
fi

# ================================================================================================
step "STAGE engine: reconfigure + ninja-relink (recompiles LocalNavigable.cpp + Application.cpp)"
# ================================================================================================
export LB_STAGED_PREFIX=$XIOS_PREFIX
export PKG_CONFIG_PATH=$XIOS_PREFIX/usr/lib/pkgconfig:$XIOS_PREFIX/usr/share/pkgconfig
export PKG_CONFIG_LIBDIR=$XIOS_PREFIX/usr/lib/pkgconfig:$XIOS_PREFIX/usr/share/pkgconfig
export LB_SHIM="$SHIM"
export LB_HOST_GEN_ASM_OFFSETS="$HOST/gen_asm_offsets"
export LB_HOST_ASMINTGEN="$HOST/asmintgen"
if run_stage engine; then
  cd "$WORK"
  rm -f "$BUILD/CMakeCache.txt"
  cmake -GNinja -B "$BUILD" -S "$WORK" \
    -DCMAKE_TOOLCHAIN_FILE=/work/recipes-ladybird/ios-toolchain.cmake \
    -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DENABLE_GUI_TARGETS=ON \
    -DENABLE_INSTALL_HEADERS=OFF -DENABLE_NETWORK_DOWNLOADS=ON -DENABLE_CLANG_PLUGINS=OFF \
    -DENABLE_CRANELIFT_JIT=OFF -DRUST_TARGET_TRIPLE=aarch64-apple-ios \
    -DLADYBIRD_CACHE_DIR="${XIOS_PREFIX:-/var}/lib/ladybird" -DVCPKG_ROOT= 2>&1 | tail -4
  echo "reconfigure exit: ${PIPESTATUS[0]}"
  cd "$BUILD"
  TARGETS="WebContent RequestServer ImageDecoder WebWorker headless-shot"
  ninja -k 0 -j"$(nproc)" $TARGETS 2>&1 | tee /out/wave4c-build.log | tail -25
  p1=${PIPESTATUS[0]}
  if [ "$p1" -ne 0 ]; then
    echo "== pass1 exit $p1; -j2 retry for OOM-killed giants =="
    ninja -k 0 -j2 $TARGETS 2>&1 | tee -a /out/wave4c-build.log | tail -25
    echo "build exit (pass2): ${PIPESTATUS[0]}"
  else
    echo "build exit: 0"
  fi
  echo "== emitted binaries =="
  for b in headless-shot WebContent RequestServer ImageDecoder WebWorker; do
    p=$(find "$BUILD" -maxdepth 4 -type f -name "$b" 2>/dev/null | head -1)
    if [ -n "$p" ]; then
      echo "$b: $(file -b "$p" | cut -c1-30) | $(file -b "$p" | grep -o NOUNDEF || echo '-')"
    else echo "$b: NOT BUILT"; fi
  done
fi

# ================================================================================================
step "STAGE package: ladybird-headless deb @ 0.1.1+ios1"
# ================================================================================================
LDID=/root/cctools/bin/ldid
VER="0.1.1+ios1"
DEB=/out/ladybird-headless_${VER}_iphoneos-arm64.deb
if run_stage package; then
  HS=$(find "$BUILD" -maxdepth 4 -type f -name headless-shot 2>/dev/null | head -1)
  if [ -z "$HS" ]; then echo "!! headless-shot not built; skipping package"; else
    PKG=/tmp/lbpkg; rm -rf "$PKG"
    mkdir -p "$PKG/DEBIAN" "$PKG$XIOS_PREFIX/usr/bin" "$PKG$XIOS_PREFIX/usr/libexec" "$PKG$XIOS_PREFIX/usr/share/Lagom"
    ENT=/tmp/ladybird-headless-ent.xml
    cat > "$ENT" <<PLIST
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
$(xios_ent_prefix_paths)
        <string>/tmp/</string>
        <string>/var/</string>
        <string>/private/var/</string>
    </array>
</dict>
</plist>
PLIST
    sign() { "$LDID" -S"$ENT" "$1" 2>/dev/null || "$LDID" -S "$1"; }
    cp "$HS" "$PKG$XIOS_PREFIX/usr/bin/headless-shot"; sign "$PKG$XIOS_PREFIX/usr/bin/headless-shot"
    for b in WebContent RequestServer ImageDecoder WebWorker; do
      p=$(find "$BUILD" -maxdepth 4 -type f -name "$b" 2>/dev/null | head -1)
      if [ -n "$p" ]; then cp "$p" "$PKG$XIOS_PREFIX/usr/libexec/$b"; sign "$PKG$XIOS_PREFIX/usr/libexec/$b"; else echo "!! helper $b missing"; fi
    done
    cp -a "$WORK"/Base/res/. "$PKG$XIOS_PREFIX/usr/share/Lagom/"
    INSTALLED_KB=$(du -sk "$PKG${XIOS_PREFIX:-/usr}" | cut -f1)
    cat > "$PKG/DEBIAN/control" <<EOF
Package: ladybird-headless
Name: Ladybird (headless renderer)
Version: $VER
Architecture: iphoneos-arm64
Description: Ladybird browser engine — headless PNG renderer (M0, real pixels).
 Multiprocess LibWeb engine (WebContent/RequestServer/ImageDecoder/WebWorker) with a
 headless-shot driver that loads a URL/HTML and dumps a PNG. iOS paints via an in-process
 CPU (Skia raster) path; no Compositor/GPU process.
Section: Utilities
Maintainer: Max Leiter <maxwell.leiter@gmail.com>
Author: Ladybird contributors; iOS port by Max Leiter
Installed-Size: $INSTALLED_KB
MinimumOSVersion: 16.0
EOF
    dpkg-deb -Zxz -b "$PKG" "$DEB" && echo "== packaged $DEB ==" && ls -la "$DEB"
    dpkg-deb -c "$DEB" | awk '{print $6}' | grep -E 'bin/|libexec/' | head
  fi
fi
echo; echo "########## WAVE 4c (stage=$LB_STAGE) done ##########"
