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
