#!/usr/bin/env bash
# build-kf6.sh — cross-build the KDE Frameworks 6 layer (plus the Plasma-released
# libraries kwayland/kdecoration/kglobalacceld/plasma-activities/layer-shell-qt) on top
# of the Qt 6 debs, OFF-DEVICE. Layer K of x11/docs/kde-plasma-plan.md; the recipe set
# and the build order both come from the K0 audit (tools/gen-kf6-recipes.py prints the
# canonical TARGETS string). Companion to build-qt.sh / build-qt-modules.sh; same volume
# rules: runs on procursus-vol-qt or a clone, NEVER concurrently with another build
# script on the same volume.
#
#   docker run --rm --platform linux/arm64 --cpus=8 \
#     -v procursus-vol-qt:/work/Procursus \
#     -v "$PWD/build-kf6.sh:/work/build-kf6.sh:ro" -v "$PWD/recipes:/work/recipes:ro" \
#     -v "$PWD/build_info:/work/build_info:ro" -v "$PWD/out:/out" \
#     procursus-xbuild:bookworm-arm64 -c 'bash /work/build-kf6.sh' 2>&1 | tee kf6-build.log
#
# TWO-STAGE, like build-qt-modules.sh, but stage 1 is KDE's cross mechanism instead of
# Qt's: frameworks that ship BUILD-TIME tools (kconfig -> kconfig_compiler_kf6,
# kcoreaddons -> desktoptojson, kpackage -> kpackagetool6) are built NATIVELY into
# build_tools/kf6-host, and the cross builds resolve them through -DKF6_HOST_TOOLING
# (each framework's Config.cmake includes the host ToolingTargets file when
# CMAKE_CROSSCOMPILING — the branch Android KDE builds use). karchive and ki18n are in
# the host set only as deps of host kpackage. Qt-side host codegen (moc, qmlcachegen,
# qmltyperegistrar, qsb) keeps flowing through QT_HOST_PATH exactly as in the module
# builds; there is still no on-device-scan wall anywhere in the KDE track.
set -euo pipefail

QTVER=6.6.3
KFVER=6.3.0
HOSTQT=/work/Procursus/build_tools/host-qt-${QTVER}
KF6HOST=/work/Procursus/build_tools/kf6-host
BB=/work/Procursus/build_base/iphoneos-arm64-rootless/1900/var/jb

# Audit wave order (regenerate with tools/gen-kf6-recipes.py; do not hand-shuffle).
TARGETS="${TARGETS:-extra-cmake-modules plasma-wayland-protocols kcoreaddons karchive kcodecs kconfig kwidgetsaddons kitemviews kitemmodels kdbusaddons kglobalaccel kguiaddons kwindowsystem kidletime ki18n solid sonnet kirigami breeze-icons kwayland plasma-activities layer-shell-qt kauth kcrash kcolorscheme kservice kpackage knotifications kcompletion kdecoration kconfigwidgets kjobwidgets ksvg kiconthemes kbookmarks ktextwidgets kxmlgui kio kcmutils kglobalacceld}"

cd /work/Procursus

# --- gates ---------------------------------------------------------------------------
# qtbase must be the ROUND 2 build (plan Q3): KF6 hard-requires QtDBus, and kxmlgui
# (wave 4) additionally requires QtPrintSupport. Round 1 debs fail here on purpose.
[ -x "${HOSTQT}/libexec/moc" ] || { echo "ERROR: host Qt missing (${HOSTQT}); run build-qt.sh first." >&2; exit 1; }
# Volume-lineage gate: kguiaddons/kidletime/kwayland protocol codegen resolves the HOST
# qtwaylandscanner through QT_HOST_PATH (build-qt-modules.sh stage 1's marker). A volume
# cloned before the module layer has a bare-qtbase host Qt and would fail mid-wave-0;
# re-running build-qt-modules.sh stage 1 on such a clone is safe (marker-gated no-op).
[ -x "${HOSTQT}/libexec/qtwaylandscanner" ] || { echo "ERROR: host Qt lacks qtwayland (${HOSTQT}/libexec/qtwaylandscanner) — clone from the post-modules volume or re-run build-qt-modules.sh stage 1." >&2; exit 1; }
[ -f "${BB}/usr/lib/cmake/Qt6/Qt6Config.cmake" ] || { echo "ERROR: cross qtbase not staged in build_base." >&2; exit 1; }
[ -f "${BB}/usr/lib/cmake/Qt6DBus/Qt6DBusConfig.cmake" ] || { echo "ERROR: staged qtbase has no QtDBus — need the round-2 qtbase (plan Q3: dbus+xkbcommon+printsupport)." >&2; exit 1; }
[ -f "${BB}/usr/lib/cmake/Qt6Qml/Qt6QmlConfig.cmake" ] || { echo "ERROR: qtdeclarative not staged (build-qt-modules.sh first)." >&2; exit 1; }
[ -f "${BB}/usr/lib/cmake/Qt6WaylandClient/Qt6WaylandClientConfig.cmake" ] || { echo "ERROR: qtwayland not staged (kguiaddons/kwindowsystem/kidletime/kwayland need it)." >&2; exit 1; }
[ -f "${BB}/usr/lib/cmake/Qt6Svg/Qt6SvgConfig.cmake" ] || { echo "ERROR: qtsvg not staged (kirigami/ksvg/kiconthemes need it)." >&2; exit 1; }
[ -f "${BB}/usr/lib/cmake/Qt6ShaderTools/Qt6ShaderToolsConfig.cmake" ] || { echo "ERROR: qtshadertools not staged (kirigami bakes shaders)." >&2; exit 1; }
[ -f "${BB}/usr/lib/pkgconfig/wayland-client.pc" ] || { echo "ERROR: wayland (W0) not staged." >&2; exit 1; }
[ -f "${BB}/usr/include/libintl.h" ] || { echo "ERROR: libintl (libgtkintl / proxy-libintl) not staged — ki18n needs it." >&2; exit 1; }
[ -e "${BB}/usr/include/EGL/egl.h" ] || { echo "ERROR: EGL headers not staged (ANGLE/epoxy chain) — kwayland links EGL." >&2; exit 1; }
case " ${TARGETS} " in *" kxmlgui "*)
  [ -f "${BB}/usr/lib/cmake/Qt6PrintSupport/Qt6PrintSupportConfig.cmake" ] || { echo "ERROR: kxmlgui needs QtPrintSupport (round-2 qtbase, FEATURE_printsupport=ON, cups OFF)." >&2; exit 1; }
esac
case " ${TARGETS} " in *" kio "*)
  [ -f "${BB}/usr/lib/cmake/Qt6Core5Compat/Qt6Core5CompatConfig.cmake" ] || { echo "ERROR: kio needs Qt6Core5Compat — build/stage the qt5compat module (audit gap, qt-modules track)." >&2; exit 1; }
esac

# --- host build deps (framework codegen + parsers + i18n) -----------------------------
apt-get update >/dev/null 2>&1 || true
apt-get install -y --no-install-recommends \
  gperf bison flex gettext python3 zlib1g-dev \
  libwayland-dev libwayland-bin wayland-protocols >/dev/null 2>&1 || true

download() { # <tarball> <url>
  if [ ! -f "build_source/$1" ]; then
    echo "==> downloading $1"
    curl -fL -o "build_source/$1.tmp" "$2"
    mv "build_source/$1.tmp" "build_source/$1"
  fi
}
mkdir -p build_source

# --- stage 1: host KF6 tooling (one-time each, marker-gated) --------------------------
host_kf() { # <name> <marker-relative-to-KF6HOST>
  local name=$1 marker=$2
  if [ -e "${KF6HOST}/${marker}" ]; then
    echo "==> host ${name} already present (${marker})"
    return
  fi
  local tarball=${name}-${KFVER}.tar.xz
  local builddir=/work/Procursus/build_tools/host-${name}-build
  download "${tarball}" "https://download.kde.org/stable/frameworks/${KFVER%.*}/${tarball}"
  echo "==> building HOST ${name} ${KFVER} into ${KF6HOST} (one-time)"
  rm -rf "/work/host-${name}-src"
  mkdir -p "/work/host-${name}-src" "${builddir}"
  tar xf "build_source/${tarball}" -C "/work/host-${name}-src" --strip-components=1
  cmake -S "/work/host-${name}-src" -B "${builddir}" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${KF6HOST}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_PREFIX_PATH="${HOSTQT};${KF6HOST}" \
    -DBUILD_TESTING=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE
  ninja -C "${builddir}"
  ninja -C "${builddir}" install
  rm -rf "/work/host-${name}-src" "${builddir}"
  echo "==> host ${name} done"
}

host_kf extra-cmake-modules share/ECM/cmake/ECMConfig.cmake
host_kf kcoreaddons       lib/cmake/KF6CoreAddons/KF6CoreAddonsConfig.cmake
host_kf karchive          lib/cmake/KF6Archive/KF6ArchiveConfig.cmake
host_kf kconfig           lib/cmake/KF6Config/KF6ConfigConfig.cmake
host_kf ki18n             lib/cmake/KF6I18n/KF6I18nConfig.cmake
host_kf kpackage          lib/cmake/KF6Package/KF6PackageConfig.cmake

# --- stage 1.5: park staged libxpc headers that shadow the SDK (same as build-qt.sh) --
# NOTE: this driver-level parking is NOT sufficient on its own — Procursus `setup`
# re-stages xpc/ + os/log.h on every make invocation (proven in the Qt module ladder),
# so the authoritative fix is $(call QT6_RM_SHADOW_HEADERS) emitted as the last line of
# every unit's -setup by gen-kf6-recipes.py. This block just cleans the state the first
# unit's make would otherwise inherit from earlier drivers.
BB_INC=${BB}/usr/include
if [ -d "${BB_INC}/xpc" ] && [ ! -d "${BB_INC}/.parked-xpc" ]; then
  echo "==> parking staged xpc/ headers (shadow the 16.4 SDK)"
  mv "${BB_INC}/xpc" "${BB_INC}/.parked-xpc"
fi

# --- cc-nounused wrappers (same as build-qt.sh / build-qt-modules.sh) ------------------
cat > build_tools/cc-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
EOF
cat > build_tools/cxx-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
EOF
chmod +x build_tools/cc-nounused build_tools/cxx-nounused

# --- stage 2: Procursus cross builds ---------------------------------------------------
echo "==> installing KF6 recipes into makefiles/"
# qt6-common.mk is a hard prerequisite: kf6-common.mk builds on its flag block.
for r in qt6-common.mk kf6-common.mk; do
  cp -v /work/recipes/$r makefiles/
done
for t in $TARGETS; do
  cp -v /work/recipes/$t.mk makefiles/
done
cp -v /work/build_info/kf6-*.control build_info/ 2>/dev/null || true
for c in extra-cmake-modules plasma-wayland-protocols plasma-activities kwayland \
         kdecoration kglobalacceld layer-shell-qt; do
  cp -v /work/build_info/$c*.control build_info/ 2>/dev/null || true
done

COMMON="MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900 NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

for t in $TARGETS; do
  echo "==> make ${t}-package"
  make ${t}-package $COMMON -j"$(nproc)"
done

# collect any debs produced
mkdir -p /out
find . \( -name "kf6-*_*_iphoneos-arm64.deb" \
       -o -name "extra-cmake-modules_*_iphoneos-arm64.deb" \
       -o -name "plasma-*_*_iphoneos-arm64.deb" \
       -o -name "kwayland*_*_iphoneos-arm64.deb" \
       -o -name "kdecoration*_*_iphoneos-arm64.deb" \
       -o -name "kglobalacceld*_*_iphoneos-arm64.deb" \
       -o -name "layer-shell-qt*_*_iphoneos-arm64.deb" \) \
  -exec cp -v {} /out/ \; 2>/dev/null || true
echo "==> done"
