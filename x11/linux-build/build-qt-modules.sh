#!/usr/bin/env bash
# Cross-builds the Qt 6 module layer on top of qtbase for rootless iOS, OFF-DEVICE. Build order
# matters: qtdeclarative needs qtshadertools' cmake package already staged in build_base.
#
# Companion to build-qt.sh (qtbase) — a separate script so it can be edited without touching
# build-qt.sh while that build is in flight. Must never run concurrently with build-qt.sh on
# the same volume.
#
#   docker run --rm --platform linux/arm64 --cpus=8 \
#     -v procursus-vol-qt:/work/Procursus \
#     -v "$PWD/build-qt-modules.sh:/work/build-qt-modules.sh:ro" -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/build_info:/work/build_info:ro" -v "$PWD/out:/out" \
#     -e TARGETS="qtshadertools qtdeclarative qt5compat qtwayland qtsvg qtimageformats" \
#     procursus-xbuild:bookworm-arm64 -c 'bash /work/build-qt-modules.sh' 2>&1 | tee qt-modules-build.log
#
# Two-stage like build-qt.sh. Stage 1 extends the host Qt with per-module host tools a cross
# module build resolves via QT_HOST_PATH (qsb, qmlcachegen, qtwaylandscanner); qmltyperegistrar
# already ships with host qtbase since 6.3. All codegen being host-side is why this track has
# no separate introspection step. Stage 2 is the Procursus cross build via recipes/qt*.mk.
set -euo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"

QTVER=6.6.3
QTMINOR=6.6
HOSTQT=/work/Procursus/build_tools/host-qt-${QTVER}
BB=$XIOS_SYSROOT
TARGETS="${TARGETS:-qtshadertools qtdeclarative qt5compat qtwayland qtsvg qtimageformats}"

cd /work/Procursus

# --- gates: qtbase must be DONE (host + cross-staged) before any module builds ---
if [ ! -x "${HOSTQT}/libexec/moc" ]; then
  echo "ERROR: host Qt ${QTVER} missing (${HOSTQT}). Run build-qt.sh first." >&2
  exit 1
fi
if [ ! -f "${BB}/usr/lib/cmake/Qt6/Qt6Config.cmake" ]; then
  echo "ERROR: cross qtbase not staged into build_base yet. Finish build-qt.sh (qtbase-package) first." >&2
  exit 1
fi
case " ${TARGETS} " in *" qtwayland "*)
  if [ ! -f "${BB}/usr/lib/pkgconfig/wayland-client.pc" ]; then
    echo "ERROR: wayland-client not staged in build_base (W0 track). qtwayland needs it; stage the wayland recipe output first." >&2
    exit 1
  fi
esac

download() { # <tarball>
  if [ ! -f "build_source/$1" ]; then
    echo "==> downloading $1"
    curl -fL -o "build_source/$1.tmp" "https://download.qt.io/archive/qt/${QTMINOR}/${QTVER}/submodules/$1"
    mv "build_source/$1.tmp" "build_source/$1"
  fi
}
mkdir -p build_source

# --- stage 1: host module tools into the existing host Qt (one-time each, marker-gated) ---
# Native builds against the host qtbase; bundled 3rdparty where possible. Build dirs live in
# build_tools/ so a failed run can resume; wiped after install.
host_module() { # <module> <marker-relative-to-HOSTQT> [extra cmake flags...]
  local mod=$1 marker=$2; shift 2
  if [ -e "${HOSTQT}/${marker}" ]; then
    echo "==> host ${mod} already present (${marker})"
    return
  fi
  local tarball=${mod}-everywhere-src-${QTVER}.tar.xz
  local builddir=/work/Procursus/build_tools/host-${mod}-build
  download "${tarball}"
  echo "==> building HOST ${mod} ${QTVER} into ${HOSTQT} (one-time)"
  rm -rf "/work/host-${mod}-src"
  mkdir -p "/work/host-${mod}-src" "${builddir}"
  tar xf "build_source/${tarball}" -C "/work/host-${mod}-src" --strip-components=1
  cmake -S "/work/host-${mod}-src" -B "${builddir}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${HOSTQT}" \
    -DCMAKE_PREFIX_PATH="${HOSTQT}" \
    -DQT_BUILD_EXAMPLES=OFF -DQT_BUILD_TESTS=OFF -DQT_BUILD_BENCHMARKS=OFF \
    "$@"
  # Full-speed first, then -j2 retry: the Docker VM's 16 CPUs but ~7.7GiB RAM means ninja's
  # default parallelism OOM-kills gcc on qtdeclarative's 2-3GiB qmldom TUs. Survivor objects
  # are kept, so the retry only rebuilds the heavy stragglers.
  ninja -C "${builddir}" || ninja -C "${builddir}" -j2
  ninja -C "${builddir}" install
  rm -rf "/work/host-${mod}-src" "${builddir}"
  echo "==> host ${mod} done"
}

host_module qtshadertools bin/qsb
# Marker is bin/qmlprofiler, not libexec/qmlcachegen: qmlprofiler only installs when
# FEATURE_qml_profiler=ON, so a host tree built before that flag existed is correctly detected
# as stale and rebuilt, rather than matching the qmlcachegen marker and silently skipping a
# host Qt6QmlTools that the cross build needs (see recipes/qtdeclarative.mk).
host_module qtdeclarative bin/qmlprofiler -DFEATURE_qml_jit=OFF -DFEATURE_qml_profiler=ON -DFEATURE_qml_preview=ON
# host qtwayland needs host wayland headers + the plain wayland-scanner; the CROSS qtwayland
# also find_program()s wayland-scanner on the host (Wayland::Scanner), so install both here
# even if the host qtwayland is already built.
apt-get update >/dev/null 2>&1 || true
apt-get install -y --no-install-recommends libwayland-dev libwayland-bin wayland-protocols >/dev/null 2>&1 || true
host_module qtwayland libexec/qtwaylandscanner -DFEATURE_wayland_server=OFF

# --- stage 1.5: park staged libxpc headers that shadow the SDK (same as build-qt.sh; the
# volume may be a fresh clone where build-qt.sh never ran). Idempotent. ---
BB_INC=${BB}/usr/include
if [ -d "${BB_INC}/xpc" ] && [ ! -d "${BB_INC}/.parked-xpc" ]; then
  echo "==> parking staged xpc/ headers (shadow the ${QTVER} build's 16.4 SDK)"
  mv "${BB_INC}/xpc" "${BB_INC}/.parked-xpc"
fi

# --- cc-nounused wrappers (same as build-qt.sh / build-mutter.sh) ---
cat > build_tools/cc-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
EOF
cat > build_tools/cxx-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
EOF
chmod +x build_tools/cc-nounused build_tools/cxx-nounused

# --- stage 2: Procursus cross builds (recipes + control files, then make <target>-package) ---
echo "==> installing qt module recipes into makefiles/"
for r in qt6-common.mk qtshadertools.mk qtdeclarative.mk qt5compat.mk qtwayland.mk qtsvg.mk qtimageformats.mk; do
  [ -f /work/recipes/$r ] && cp -v /work/recipes/$r makefiles/
done
cp -v /work/build_info/qt6-*.control build_info/ 2>/dev/null || true
mkdir -p build_misc/entitlements
if [ -f /work/build_info/iosc-gpu-client-ent.xml ]; then
  cp -v /work/build_info/iosc-gpu-client-ent.xml build_misc/entitlements/
fi

case " ${TARGETS} " in *" qtwayland "*)
  if ls /out/angle_*_iphoneos-arm64.deb >/dev/null 2>&1; then
    ANGLE_DEB=$(ls /out/angle_*_iphoneos-arm64.deb 2>/dev/null | grep -E '\+es3-[0-9]+' | sort -V | tail -1 || true)
    [ -n "$ANGLE_DEB" ] || ANGLE_DEB=$(ls /out/angle_*_iphoneos-arm64.deb 2>/dev/null | grep '+es3' | sort -V | tail -1 || true)
    [ -n "$ANGLE_DEB" ] || ANGLE_DEB=$(ls /out/angle_*_iphoneos-arm64.deb 2>/dev/null | sort -V | tail -1)
    echo "==> staging ANGLE for qtwayland EGL integration: ${ANGLE_DEB}"
    rm -rf /tmp/angle-qt && mkdir -p /tmp/angle-qt
    dpkg-deb -x "$ANGLE_DEB" /tmp/angle-qt
    mkdir -p "$BB"
    cp -a /tmp/angle-qt$XIOS_PREFIX/* "$BB"/
  else
    echo "WARN: no angle deb in /out; qtwayland may skip/fail EGL integration"
  fi
esac

COMMON="$XIOS_MEMO_ARGS NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

XIOS_CACHE_COMMON_INPUTS="/work/recipes/qt6-common.mk"
source /work/recipes/xios-cache-fingerprint.sh

for t in $TARGETS; do
  echo "==> make ${t}-package"
  xios_cache_prepare_target "$t"
  make ${t}-package $COMMON -j"$(nproc)"
  xios_cache_record_target "$t"
done

# collect any debs produced
mkdir -p /out
find . -name "qt6-*_*_iphoneos-arm64.deb" -exec cp -v {} /out/ \; 2>/dev/null || true
echo "==> done"
