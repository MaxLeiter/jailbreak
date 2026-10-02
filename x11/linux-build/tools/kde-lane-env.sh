#!/bin/sh
# Sourced by the KDE 6.10 lane drivers (build-qt.sh, build-qt-modules.sh, build-kf6.sh, ...).
# KF6 6.25+ (and so 6.30) need CMake >= 3.29 and Qt 6.10 itself wants a recent one; the toolchain image carries
# Debian bookworm's 3.25. Rather than edit the shared image, this installs Kitware's cmake into the build volume
# (build_tools/, persisted) once and puts it first on PATH. Idempotent.
KDE_CMAKE_VER=${KDE_CMAKE_VER:-3.31.8}
KDE_CMAKE_DIR=/work/Procursus/build_tools/cmake-${KDE_CMAKE_VER}
if [ ! -x "$KDE_CMAKE_DIR/bin/cmake" ]; then
  echo "==> installing cmake ${KDE_CMAKE_VER} into ${KDE_CMAKE_DIR}"
  mkdir -p "$KDE_CMAKE_DIR"
  curl -fL "https://github.com/Kitware/CMake/releases/download/v${KDE_CMAKE_VER}/cmake-${KDE_CMAKE_VER}-linux-aarch64.tar.gz" \
    | tar xz -C "$KDE_CMAKE_DIR" --strip-components=1
fi
export PATH="$KDE_CMAKE_DIR/bin:$PATH"
cmake --version | head -1

# Cap ninja at KDE_NINJA_JOBS (default 10) for every build in the lane: the 27 GiB Docker VM is shared with the WebKit
# build, and an uncapped -j18 KDE compile next to it got the container OOM-killed with no error in the log.
# The wrapper lives next to the volume's cmake (first on PATH, also through make's PATH override) and only adds -j when
# the caller did not pass one.
if [ ! -x "$KDE_CMAKE_DIR/bin/ninja" ] || ! grep -q KDE_NINJA_JOBS "$KDE_CMAKE_DIR/bin/ninja" 2>/dev/null; then
  cat > "$KDE_CMAKE_DIR/bin/ninja" <<'W'
#!/bin/sh
for a in "$@"; do case "$a" in -j*) exec /usr/bin/ninja "$@";; esac; done
exec /usr/bin/ninja -j"${KDE_NINJA_JOBS:-10}" "$@"
W
  chmod +x "$KDE_CMAKE_DIR/bin/ninja"
fi

# kde_lane_pmr_setup: call AFTER xios_clang19_setup. Builds tools/xios-pmr-shim (std::pmr is missing from the 16.5
# libc++ dylib, see that README) and swaps XIOS_CXX19 for a wrapper that appends `-L<dir> -Wl,-hidden-lxios-pmr` to
# LINK invocations only (hidden: no KDE dylib re-exports std::pmr symbols).
kde_lane_pmr_setup() {
  here=/work/x11/linux-build/tools/xios-pmr-shim
  bash "$here/build.sh" || return 1
  pmr_dir="${XIOS_PMR_DIR:-/work/Procursus/build_tools/xios-pmr}"
  real_cxx="${XIOS_CXX19_REAL:-$XIOS_CXX19}"
  wrap="$(dirname "$real_cxx")/cxx19-kde"
  cat > "$wrap.tmp" <<W
#!/usr/bin/env bash
link=1
for a in "\$@"; do case "\$a" in -c|-E|-S|-fsyntax-only|-M|-MM) link=0;; esac; done
if [ "\$link" = 1 ]; then exec "$real_cxx" "\$@" -L$pmr_dir -Wl,-hidden-lxios-pmr; fi
exec "$real_cxx" "\$@"
W
  chmod +x "$wrap.tmp"
  if ! cmp -s "$wrap.tmp" "$wrap" 2>/dev/null; then mv -f "$wrap.tmp" "$wrap"; else rm -f "$wrap.tmp"; fi
  export XIOS_CXX19_REAL="$real_cxx" XIOS_CXX19="$wrap"
  echo "kde-lane: std::pmr shim linked via $wrap"
}
