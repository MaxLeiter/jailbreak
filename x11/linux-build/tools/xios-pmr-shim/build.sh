#!/usr/bin/env bash
# Builds libxios-pmr.a into $XIOS_PMR_DIR (default: /work/Procursus/build_tools/xios-pmr). Run inside the toolchain
# container after `xios_clang19_setup` (needs $XIOS_CXX19 / $XIOS_AR19 / $XIOS_RANLIB19). Idempotent.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${XIOS_PMR_DIR:-/work/Procursus/build_tools/xios-pmr}"
: "${XIOS_CXX19:?run xios_clang19_setup first}"
mkdir -p "$out"
if [ -f "$out/libxios-pmr.a" ] && [ "$out/libxios-pmr.a" -nt "$here/memory_resource.cpp" ]; then
  echo "xios-pmr: up to date ($out/libxios-pmr.a)"; exit 0
fi
# -D_LIBCPP_DISABLE_AVAILABILITY: the definitions themselves call pmr API the 16.5 availability annotations would
# otherwise flag. -fvisibility=hidden + -hidden-l at the final link keep every symbol private to the consuming image.
"$XIOS_CXX19" -std=c++20 -O2 -fPIC -fvisibility=hidden -fno-exceptions -fno-rtti \
  -D_LIBCPP_DISABLE_AVAILABILITY -D_LIBCPP_BUILDING_LIBRARY \
  -I"$here" -c "$here/memory_resource.cpp" -o "$out/memory_resource.o"
"$XIOS_AR19" rcs "$out/libxios-pmr.a" "$out/memory_resource.o"
"$XIOS_RANLIB19" "$out/libxios-pmr.a" || true
echo "xios-pmr: built $out/libxios-pmr.a"
