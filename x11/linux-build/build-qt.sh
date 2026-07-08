#!/usr/bin/env bash
# build-qt.sh — cross-build Qt 6 (qtbase first) for rootless iOS, OFF-DEVICE. The KDE Plasma Mobile
# track's foundation; companion to build-gnome.sh / build-mutter.sh (shares their host-tool preamble
# + cc-nounused clang wrappers). Runs on a DEDICATED volume (procursus-vol-qt, a clone of the warm
# GTK volume) so it never races the active GNOME agents on procursus-vol-gtk.
#
#   docker run --rm --platform linux/arm64 --cpus=8 \
#     -v procursus-vol-qt:/work/Procursus \
#     -v "$PWD/build-qt.sh:/work/build-qt.sh:ro" -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/build_info:/work/build_info:ro" -v "$PWD/out:/out" \
#     -e TARGETS="qtbase" \
#     procursus-xbuild:bookworm-arm64 -c 'bash /work/build-qt.sh' 2>&1 | tee qt-build.log
#
# TWO-STAGE BUILD. Cross-building qtbase needs moc/rcc/uic/syncqt from a host Qt of the IDENTICAL
# version (QT_HOST_PATH). Target is 6.6.3 (Plasma 6.0/6.1 era) which no Debian ships, so stage 1
# builds a native host qtbase 6.6.3 from the same tarball into build_tools/host-qt-6.6.3 (one-time;
# persisted in the volume, ~25 min). Stage 2 is the Procursus cross build via recipes/qtbase.mk.
set -euo pipefail

QTVER=6.6.3
QTMINOR=6.6
TARBALL=qtbase-everywhere-src-${QTVER}.tar.xz
SRCURL=https://download.qt.io/archive/qt/${QTMINOR}/${QTVER}/submodules/${TARBALL}
HOSTQT=/work/Procursus/build_tools/host-qt-${QTVER}
HOSTQT_BUILD=/work/Procursus/build_tools/host-qt-build   # in-volume so a failed run can resume
BB=/work/Procursus/build_base/iphoneos-arm64-rootless/1900/var/jb

cd /work/Procursus

# --- stage 0: source tarball, shared with the recipe (DOWNLOAD_FILES skips existing files) ---
mkdir -p build_source
if [ ! -f build_source/${TARBALL} ]; then
  echo "==> downloading ${TARBALL}"
  curl -fL -o build_source/${TARBALL}.tmp ${SRCURL}
  mv build_source/${TARBALL}.tmp build_source/${TARBALL}
fi

# --- stage 1: HOST Qt (QT_HOST_PATH bootstrap; one-time, persisted in the volume) ---
# Native arm64-Linux build with Qt's bundled third-party libs (no host -dev packages except libdbus:
# QtDBus needs dbus/dbus.h even in dlopen-at-runtime mode, and Qt6DBusTools is wanted for later
# KF6/Plasma cross builds). gui+widgets ON so Qt6GuiTools/Qt6WidgetsTools (uic etc.) exist.
if [ ! -x "${HOSTQT}/libexec/moc" ]; then
  echo "==> building HOST Qt ${QTVER} into ${HOSTQT} (one-time)"
  apt-get update >/dev/null 2>&1 || true
  apt-get install -y --no-install-recommends libdbus-1-dev >/dev/null 2>&1 || true
  rm -rf /work/host-qt-src
  mkdir -p /work/host-qt-src "${HOSTQT_BUILD}"
  tar xf build_source/${TARBALL} -C /work/host-qt-src --strip-components=1
  cmake -S /work/host-qt-src -B "${HOSTQT_BUILD}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${HOSTQT}" \
    -DQT_BUILD_EXAMPLES=OFF -DQT_BUILD_TESTS=OFF -DQT_BUILD_BENCHMARKS=OFF \
    -DFEATURE_gui=ON -DFEATURE_widgets=ON \
    -DFEATURE_dbus=ON -DFEATURE_dbus_linked=OFF \
    -DFEATURE_network=OFF -DFEATURE_sql=OFF -DFEATURE_testlib=OFF \
    -DFEATURE_printsupport=OFF -DFEATURE_opengl=OFF -DINPUT_opengl=no \
    -DFEATURE_vulkan=OFF -DFEATURE_xcb=OFF -DFEATURE_xkbcommon=OFF \
    -DFEATURE_fontconfig=OFF -DFEATURE_glib=OFF -DFEATURE_icu=OFF \
    -DFEATURE_openssl=OFF -DINPUT_openssl=no \
    -DQT_QPA_DEFAULT_PLATFORM=offscreen
  ninja -C "${HOSTQT_BUILD}"
  ninja -C "${HOSTQT_BUILD}" install
  rm -rf /work/host-qt-src "${HOSTQT_BUILD}"
  echo "==> host Qt done: $(${HOSTQT}/libexec/moc --version)"
else
  echo "==> host Qt ${QTVER} already present: $(${HOSTQT}/libexec/moc --version)"
fi

# NOTE: the SDK-shadowing xpc/ headers in build_base are removed by qtbase.mk's setup step, NOT
# here — Procursus `setup` re-stages them on every make run, so a driver-level parking gets undone
# by the next build (learned the hard way: attempt 4 hit the xpc wall again after attempt 3 parked).

# --- cc-nounused wrappers (same as build-mutter.sh: neutralise meson/cmake probe -Werror) ---
cat > build_tools/cc-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
EOF
cat > build_tools/cxx-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
EOF
chmod +x build_tools/cc-nounused build_tools/cxx-nounused

# --- stage 2: Procursus cross build (recipes + control files, then make <target>-package) ---
echo "==> installing qt recipes into makefiles/"
for r in qtbase.mk; do
  [ -f /work/recipes/$r ] && cp -v /work/recipes/$r makefiles/
done
cp -v /work/build_info/qt6-*.control build_info/ 2>/dev/null || true
source /work/recipes/xios-cache-fingerprint.sh

# Qt round 3 links QtGui/EGL support against the ANGLE deb. ANGLE deliberately lives
# outside /var/jb/usr at /var/jb/lib/angle plus /var/jb/include, so stage it into the
# sysroot here instead of relying on CMAKE_FIND_ROOT_PATH.
if ls /out/angle_*_iphoneos-arm64.deb >/dev/null 2>&1; then
  ANGLE_DEB=$(ls /out/angle_*_iphoneos-arm64.deb 2>/dev/null | grep '+es3' | head -1 || true)
  [ -n "$ANGLE_DEB" ] || ANGLE_DEB=$(ls /out/angle_*_iphoneos-arm64.deb 2>/dev/null | head -1)
  echo "==> staging ANGLE for Qt GL/EGL: ${ANGLE_DEB}"
  rm -rf /tmp/angle-qt && mkdir -p /tmp/angle-qt
  dpkg-deb -x "$ANGLE_DEB" /tmp/angle-qt
  mkdir -p "$BB"
  cp -a /tmp/angle-qt/var/jb/* "$BB"/
else
  echo "WARN: no angle deb in /out; qtbase GL/EGL configure will fail until angle is staged"
fi

# Qt round 5 links QtCore against ICU (FEATURE_icu=ON, qtbase.mk). Stage the PUBLISHED 74.2
# ICU debs into the sysroot, same pattern as ANGLE above. TWO debs on purpose:
#   - libicu-dev_74.2+ios1: unicode/ headers + icu-*.pc + the UNVERSIONED .dylib symlinks.
#     MUST be the +ios1 repackage — the original libicu-dev_74.2 (no +ios1) shipped ZERO
#     headers (the gap that kept FEATURE_icu OFF through round 4; see qtbase.mk's ICU block).
#   - libicu74_74.2: the real versioned dylibs the -dev symlinks point at; without it the
#     symlinks dangle and the qtbase link step fails.
# Glob is pinned to 74.2 — out/ ALSO carries libicu78/libicu-dev_78.3 (Ladybird's EXACT pin),
# and compiling against 78 headers over the 74 runtime misses symbols at load time (ICU bakes
# U_ICU_VERSION_MAJOR_NUM into every export: ucol_open_78 vs ucol_open_74). Do NOT "upgrade"
# this glob to 78 without also switching qt6-base's Depends and re-validating apt on device.
ICU_RUNTIME_DEB=$(ls /out/libicu74_74.2*_iphoneos-arm64.deb 2>/dev/null | sort -V | tail -1 || true)
ICU_DEV_DEB=$(ls /out/libicu-dev_74.2+ios1*_iphoneos-arm64.deb 2>/dev/null | sort -V | tail -1 || true)
if [ -n "$ICU_RUNTIME_DEB" ] && [ -n "$ICU_DEV_DEB" ]; then
  echo "==> staging ICU 74.2 for Qt FEATURE_icu: ${ICU_RUNTIME_DEB} + ${ICU_DEV_DEB}"
  rm -rf /tmp/icu-qt && mkdir -p /tmp/icu-qt
  dpkg-deb -x "$ICU_RUNTIME_DEB" /tmp/icu-qt
  dpkg-deb -x "$ICU_DEV_DEB" /tmp/icu-qt
  mkdir -p "$BB"
  cp -a /tmp/icu-qt/var/jb/* "$BB"/
  if [ ! -f "$BB/usr/include/unicode/uvernum.h" ]; then
    echo "ERROR: ICU staged but unicode/uvernum.h missing — headerless -dev deb? qtbase configure will fail." >&2
    exit 1
  fi
else
  echo "ERROR: ICU 74.2 debs not found in /out (need libicu74_74.2* AND libicu-dev_74.2+ios1*)." >&2
  echo "       qtbase round 5 has FEATURE_icu=ON and cannot configure without them." >&2
  exit 1
fi

COMMON="MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900 NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

TARGETS="${TARGETS:-qtbase}"
for t in $TARGETS; do
  echo "==> make ${t}-package"
  xios_cache_prepare_target "$t"
  make ${t}-package $COMMON -j"$(nproc)"
  xios_cache_record_target "$t"
done

# collect any debs produced
mkdir -p /out
for pat in qt6-base; do
  find . -name "${pat}*_*_iphoneos-arm64.deb" -exec cp -v {} /out/ \; 2>/dev/null || true
done
echo "==> done"
