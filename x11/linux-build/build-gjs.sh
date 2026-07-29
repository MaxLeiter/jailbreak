#!/usr/bin/env bash
# Builds the gjs JS layer (mozjs115 + gjs) for rootless iOS.
# Companion to build-gtk.sh / build-gnome.sh; does NOT edit them. New recipes only.
#
# IMPORTANT: this drives the single heaviest cross in the tree (mozjs115). It is
# GATED — do not run without coordinator go (Docker is shared).
#
# The introspection typelibs gjs needs at RUNTIME are NOT produced here: they are
# generated ON THE DEVICE by ../gir-ondevice.sh (g-ir-scanner runs natively on the
# iPad to dodge the GI cross-compile wall). This script only builds the engine +
# bindings.
#
# Run in the container with procursus-vol mounted at /work/Procursus, recipes at /work/recipes,
# and the ports tree (for the mozjs patch series) at /work/ports:
#   docker run --rm --platform linux/arm64 \
#     -v procursus-vol-gtk:/work/Procursus \
#     -v "$PWD/build-gjs.sh:/work/build-gjs.sh:ro" -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/build_info:/work/build_info:ro" -v "$PWD/../ports:/work/ports:ro" \
#     -v "$PWD/out:/out" -e TARGETS="mozjs-package" procursus-xbuild:bookworm-arm64 /work/build-gjs.sh
# For the JIT variant: -e TARGETS="mozjs-jit-package".
set -euo pipefail
cd /work/Procursus

# --- host build tools mozjs115 needs that the base image lacks ---
#  * rustup toolchain (current stable) + the aarch64-apple-ios std target. Procursus rust.mk
#    is WIP/1.56 (too old); mozjs115 wants a modern rustc. This is a BUILD-HOST tool.
#  * cbindgen (Rust->C header gen), yasm/nasm, python3 (have), clang (have).
if ! command -v rustc >/dev/null 2>&1; then
  echo "==> installing rustup + aarch64-apple-ios target"
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env"
fi
source "$HOME/.cargo/env" 2>/dev/null || true
rustup target add aarch64-apple-ios
command -v cbindgen >/dev/null 2>&1 || cargo install cbindgen
command -v yasm >/dev/null 2>&1 || apt-get update >/dev/null 2>&1 && apt-get install -y --no-install-recommends yasm nasm >/dev/null 2>&1 || true

echo "==> installing our recipes into makefiles/"
cp -v /work/recipes/mozjs.mk /work/recipes/gjs.mk makefiles/
# JIT variant recipe (optional; present only when building the JIT flavor).
[ -f /work/recipes/mozjs-jit.mk ] && cp -v /work/recipes/mozjs-jit.mk makefiles/ || true

# --- stage the mozjs iOS patch series into build_patch/mozjs (repro-audit B5) ---
# DO_PATCH globs EVERY file in build_patch/<pkg> and applies it, so copy ONLY the
# numbered *.patch files — never the `series` index (patch would choke on it). The
# JIT recipe reuses the same dir, so 0005 lands here too once it exists.
if [ -d /work/ports/mozjs/patches ]; then
  echo "==> staging mozjs patches -> build_patch/mozjs"
  mkdir -p build_patch/mozjs
  for p in /work/ports/mozjs/patches/*.patch; do
    [ -e "$p" ] && cp -v "$p" build_patch/mozjs/
  done
else
  echo "WARNING: /work/ports/mozjs/patches not mounted — mozjs will build UNPATCHED (add -v \$PWD/../ports:/work/ports:ro)" >&2
fi

echo "==> installing our mozconfig + control templates"
[ -d /work/build_info ] && cp -v /work/build_info/mozjs115.mozconfig build_info/ 2>/dev/null || true
[ -d /work/build_info ] && cp -v /work/build_info/mozjs115-jit.mozconfig build_info/ 2>/dev/null || true
[ -d /work/build_info ] && compgen -G "/work/build_info/libmozjs*" >/dev/null && cp -v /work/build_info/libmozjs* build_info/ || true
[ -d /work/build_info ] && compgen -G "/work/build_info/*gjs*" >/dev/null && cp -v /work/build_info/*gjs* build_info/ || true

# Reuse the gtk build's clang wrapper trick (neutralise the -adhoc_codesign unused-arg error
# that breaks meson compile probes). gjs is meson; mozjs is mach (unaffected).
if [ -x build_tools/cc-nounused ]; then
  CCW=/work/Procursus/build_tools/cc-nounused
  CXXW=/work/Procursus/build_tools/cxx-nounused
else
  CCW=""; CXXW=""
fi

COMMON="MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900 NO_PGP=1"
[ -n "$CCW" ] && COMMON="$COMMON CC=$CCW CXX=$CXXW"
# DE-RISK FIRST: `make mozjs-configure-only` equivalent — get `mach configure` to complete for
# the cross target before the multi-hour compile. (Set TARGETS=mozjs-setup then run mach
# configure by hand the first time; it surfaces 90% of host/target tool problems cheaply.)
TARGETS="${TARGETS:-mozjs-package}"

for t in $TARGETS; do
  echo "==> make $t"
  make $t $COMMON -j"$(nproc)"
done

echo "==> collect debs -> /out"
mkdir -p /out
for pat in libmozjs libgjs gjs; do
  find . -name "${pat}*_*_iphoneos-arm64.deb" -exec cp -v {} /out/ \; 2>/dev/null || true
done
echo "==> done. NOTE: generate gjs's runtime typelibs on-device with ../gir-ondevice.sh"
