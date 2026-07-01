#!/usr/bin/env bash
# build-qt-modules.sh — cross-build the Qt 6 MODULE layer on top of qtbase for rootless iOS,
# OFF-DEVICE: qtshadertools -> qtdeclarative -> qtwayland -> qtsvg -> qtimageformats (ladder
# order matters: declarative needs shadertools' target cmake package from build_base).
# Companion to build-qt.sh (qtbase); a SEPARATE script on purpose so it can be developed and
# mounted without touching build-qt.sh while the qtbase build is in flight. Same volume rules:
# runs on procursus-vol-qt (or a clone) and must NEVER run concurrently with build-qt.sh on
# the same volume.
#
#   docker run --rm --platform linux/arm64 --cpus=8 \
#     -v procursus-vol-qt:/work/Procursus \
#     -v "$PWD/build-qt-modules.sh:/work/build-qt-modules.sh:ro" -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/build_info:/work/build_info:ro" -v "$PWD/out:/out" \
#     -e TARGETS="qtshadertools qtdeclarative qtwayland qtsvg qtimageformats" \
#     procursus-xbuild:bookworm-arm64 -c 'bash /work/build-qt-modules.sh' 2>&1 | tee qt-modules-build.log
#
# TWO-STAGE, like build-qt.sh. Stage 1 EXTENDS the host Qt (built by build-qt.sh stage 1)
# with the per-module HOST tools a cross module build resolves via QT_HOST_PATH:
#   - qtshadertools -> qsb            (bakes QtQuick shaders; needed by host+cross declarative)
#   - qtdeclarative -> qmlcachegen, qmlimportscanner (compile the modules' own QML at build time)
#   - qtwayland     -> qtwaylandscanner (generates Qt wayland protocol bindings)
# qmltyperegistrar already ships with the host qtbase (in qtbase since 6.3). This is the
# whole reason the Qt track has no introspection wall: ALL codegen is host-side.
# Stage 2 is the Procursus cross build via recipes/qt*.mk.
set -euo pipefail

QTVER=6.6.3
QTMINOR=6.6
HOSTQT=/work/Procursus/build_tools/host-qt-${QTVER}
BB=/work/Procursus/build_base/iphoneos-arm64-rootless/1900/var/jb
TARGETS="${TARGETS:-qtshadertools qtdeclarative qtwayland qtsvg qtimageformats}"

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
  ninja -C "${builddir}"
  ninja -C "${builddir}" install
  rm -rf "/work/host-${mod}-src" "${builddir}"
  echo "==> host ${mod} done"
}

host_module qtshadertools bin/qsb
host_module qtdeclarative libexec/qmlcachegen -DFEATURE_qml_jit=OFF
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
for r in qt6-common.mk qtshadertools.mk qtdeclarative.mk qtwayland.mk qtsvg.mk qtimageformats.mk; do
  [ -f /work/recipes/$r ] && cp -v /work/recipes/$r makefiles/
done
cp -v /work/build_info/qt6-*.control build_info/ 2>/dev/null || true

COMMON="MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900 NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

for t in $TARGETS; do
  echo "==> make ${t}-package"
  make ${t}-package $COMMON -j"$(nproc)"
done

# collect any debs produced
mkdir -p /out
find . -name "qt6-*_*_iphoneos-arm64.deb" -exec cp -v {} /out/ \; 2>/dev/null || true
echo "==> done"
