#!/usr/bin/env bash
# build-kde-apps.sh - cross-build the next KDE Qt6 app batch.
set -euo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"
. /work/x11/linux-build/tools/kde-lane-env.sh   # cmake >= 3.29

QTVER=6.10.3
HOSTQT=/work/Procursus/build_tools/host-qt-${QTVER}
BB=$XIOS_SYSROOT
TARGETS="${TARGETS:-phonon-package ksyntaxhighlighting-package ktexteditor-package poppler-package poppler-qt6-package kpty-package ark-package okular-package gwenview-package kwrite-package kate-package kcalc-package konsole-package dolphin-package}"
COLLECT_DEBS=(libpoppler154 libpoppler-glib8 libpoppler-dev libpoppler-qt6-3 libpoppler-qt6-dev okular libexiv2 phonon4qt6 kf6-syntax-highlighting kf6-texteditor ark gwenview kwrite kate kcalc kf6-pty konsole dolphin)

cd /work/Procursus

[ -x "${HOSTQT}/libexec/moc" ] || { echo "ERROR: host Qt missing (${HOSTQT}); run build-qt.sh first." >&2; exit 1; }
[ -f "${BB}/usr/lib/cmake/Qt6/Qt6Config.cmake" ] || { echo "ERROR: cross qtbase not staged." >&2; exit 1; }
[ -f "${BB}/usr/lib/cmake/Qt6Svg/Qt6SvgConfig.cmake" ] || { echo "ERROR: qtsvg not staged." >&2; exit 1; }
[ -f "${BB}/usr/lib/cmake/Qt6PrintSupport/Qt6PrintSupportConfig.cmake" ] || { echo "ERROR: QtPrintSupport not staged." >&2; exit 1; }
[ -f "${BB}/usr/lib/cmake/Qt6Qml/Qt6QmlConfig.cmake" ] || { echo "ERROR: QtQml not staged." >&2; exit 1; }
[ -f "${BB}/usr/lib/cmake/KF6Parts/KF6PartsConfig.cmake" ] || { echo "ERROR: KF6Parts not staged." >&2; exit 1; }
[ -f "${BB}/usr/lib/cmake/KF6TextWidgets/KF6TextWidgetsConfig.cmake" ] || { echo "ERROR: KF6TextWidgets not staged." >&2; exit 1; }

# Stage ICU 74.2 into the sysroot. konsole does
# find_package(ICU 61.0 COMPONENTS uc i18n REQUIRED) and, with no ICU in the
# cross sysroot, CMake happily resolves it to the BUILD CONTAINER's host ICU
# (70.2 on bookworm) and then fails. Mirrors build-qt.sh, including its pin:
# out/ also carries libicu78/libicu-dev_78.3, and compiling against 78 headers
# over the 74 runtime misses symbols at load time, because ICU bakes
# U_ICU_VERSION_MAJOR_NUM into every export (ucol_open_78 vs ucol_open_74).
# Do NOT point this at 78 without also moving qt6-base's Depends.
ICU_RUNTIME_DEB=$(ls /out/libicu74_74.2*_$XIOS_DEB_ARCH.deb 2>/dev/null | sort -V | tail -1 || true)
ICU_DEV_DEB=$(ls /out/libicu-dev_74.2+ios1*_$XIOS_DEB_ARCH.deb 2>/dev/null | sort -V | tail -1 || true)
if [ -n "$ICU_RUNTIME_DEB" ] && [ -n "$ICU_DEV_DEB" ]; then
  if [ ! -f "${BB}/usr/include/unicode/uvernum.h" ]; then
    echo "==> staging ICU 74.2: ${ICU_RUNTIME_DEB} + ${ICU_DEV_DEB}"
    rm -rf /tmp/icu-apps && mkdir -p /tmp/icu-apps
    dpkg-deb -x "$ICU_RUNTIME_DEB" /tmp/icu-apps
    dpkg-deb -x "$ICU_DEV_DEB" /tmp/icu-apps
    cp -a /tmp/icu-apps$XIOS_PREFIX/* "${BB}"/
    [ -f "${BB}/usr/include/unicode/uvernum.h" ] || { echo "ERROR: ICU staged but unicode/uvernum.h missing." >&2; exit 1; }
  fi
else
  echo "NOTE: ICU 74.2 debs not in /out; konsole will not configure." >&2
fi

# Lane staging (see build-kf6.sh/build-plasma-desktop.sh): libwayland >= 1.24, wayland-protocols, libgtkintl shim,
# exiv2/poppler runtime+dev debs from /out, then mode B (clang-19 + LLVM-19 libc++ headers, minos 16.5).
for pkg in libwayland0 libwayland-dev wayland-protocols libexiv2-28 libexiv2-dev libpoppler154 libpoppler-dev libpoppler-glib8; do
  d=$(ls /out/${pkg}_*_$XIOS_DEB_ARCH.deb 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$d" ] && { echo "==> staging $(basename "$d")"; rm -rf /tmp/stg && mkdir -p /tmp/stg && dpkg-deb -x "$d" /tmp/stg && cp -a /tmp/stg$XIOS_PREFIX/* "$BB"/; }
done
bash /work/recipes/ensure-gtkintl-build-shim.sh
. /work/x11/linux-build/tools/xios-clang19-env.sh
export XIOS_IOS_MIN=${XIOS_IOS_MIN:-16.5}
xios_clang19_setup

apt-get update >/dev/null 2>&1 || true
apt-get install -y --no-install-recommends \
  gettext python3 perl gzip libmount-dev libdbus-1-dev libxkbcommon-dev libwayland-dev libwayland-bin >/dev/null 2>&1 || true

cat > build_tools/cc-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
EOF
cat > build_tools/cxx-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
EOF
chmod +x build_tools/cc-nounused build_tools/cxx-nounused

echo "==> installing KDE app recipes into makefiles/"
mkdir -p build_info build_misc/entitlements
for r in \
  qt6-common.mk kf6-common.mk \
  poppler.mk poppler-qt6.mk okular.mk phonon.mk ksyntaxhighlighting.mk ktexteditor.mk \
  ark.mk gwenview.mk kwrite.mk \
  kate.mk kcalc.mk kpty.mk konsole.mk dolphin.mk; do
  cp -v /work/recipes/$r makefiles/
done
cp -v /work/recipes/kpty-ios-fixes.sh build_info/ 2>/dev/null || true
cp -v /work/recipes/konsole-ios-fixes.sh build_info/ 2>/dev/null || true
cp -v /work/recipes/kate-ios-fixes.sh build_info/ 2>/dev/null || true
cp -v /work/build_info/* build_info/ 2>/dev/null || true
cp -v /work/build_info/iosc-*.xml build_misc/entitlements/ 2>/dev/null || true

COMMON="$XIOS_MEMO_ARGS NO_PGP=1 \
  PATH=$KDE_CMAKE_DIR/bin:/root/cctools/bin:/work/Procursus/build_tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  LD_LIBRARY_PATH=/root/cctools/lib \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

XIOS_CACHE_COMMON_INPUTS="/work/recipes/qt6-common.mk /work/recipes/kf6-common.mk"
source /work/recipes/xios-cache-fingerprint.sh

for t in $TARGETS; do
  echo "==> make ${t}"
  xios_cache_prepare_target "$t"
  make "${t}" $COMMON -j"$(nproc)"
  xios_cache_record_target "$t"
done

echo "==> collect KDE app debs -> /out"
mkdir -p /out
for pkg in "${COLLECT_DEBS[@]}"; do
  while IFS= read -r deb; do
    [ -e "$deb" ] && cp -v "$deb" /out/
  done < <(find build_dist/$XIOS_TRIPLE -maxdepth 2 -type f \( \
    -name "${pkg}_*.deb" -o \
    -name "${pkg}-28_*.deb" -o \
    -name "${pkg}-dev_*.deb" \
  \) | sort)
done
echo "==> done"
