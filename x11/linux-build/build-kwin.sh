#!/usr/bin/env bash
# Cross-builds nested KWin Wayland with the Xios ANGLE/Metal and
# IOSurface backend on top of the completed Qt/KF6 volume. Linux DRM/libinput and
# native backends remain deliberately trimmed on iOS.
set -euo pipefail

QTVER=6.6.3
BB=/work/Procursus/build_base/iphoneos-arm64-rootless/1900/var/jb
HOSTQT=/work/Procursus/build_tools/host-qt-${QTVER}

TARGETS="${TARGETS:-libdrm-package gbm-package libdisplay-info-package kwin-package}"

cd /work/Procursus

[ -x "${HOSTQT}/libexec/moc" ] || { echo "ERROR: host Qt missing (${HOSTQT}); run build-qt.sh first." >&2; exit 1; }
[ -x "${HOSTQT}/libexec/qtwaylandscanner" ] || { echo "ERROR: host Qt lacks qtwaylandscanner; run build-qt-modules.sh first." >&2; exit 1; }
for f in \
  usr/lib/cmake/Qt6UiTools/Qt6UiToolsConfig.cmake \
  usr/lib/cmake/Qt6Sensors/Qt6SensorsConfig.cmake \
  usr/lib/cmake/KF6CoreAddons/KF6CoreAddonsConfig.cmake \
  usr/lib/cmake/KDecoration2/KDecoration2Config.cmake \
  usr/lib/cmake/KGlobalAccelD/KGlobalAccelDConfig.cmake \
  usr/lib/cmake/KWayland/KWaylandConfig.cmake \
  usr/lib/pkgconfig/wayland-client.pc \
  usr/lib/pkgconfig/wayland-server.pc \
  usr/lib/pkgconfig/xkbcommon.pc; do
  [ -e "${BB}/${f}" ] || { echo "ERROR: missing staged dependency ${f}" >&2; exit 1; }
done

apt-get update >/dev/null 2>&1 || true
apt-get install -y --no-install-recommends \
  gettext python3 libwayland-dev libwayland-bin wayland-protocols >/dev/null 2>&1 || true

cat > build_tools/cc-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
EOF
cat > build_tools/cxx-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
EOF
chmod +x build_tools/cc-nounused build_tools/cxx-nounused

echo "==> installing KWin recipes into makefiles/"
mkdir -p build_info build_misc/entitlements
for r in qt6-common.mk kf6-common.mk libdrm.mk gbm.mk libdisplay-info.mk kwin.mk; do
  cp -v /work/recipes/$r makefiles/
done
cp -v /work/build_info/*.control build_info/ 2>/dev/null || true
cp -v /work/recipes/build_info/libdrm*.control build_info/
cp -v /work/recipes/build_info/libxcvt*.control build_info/ 2>/dev/null || true
cp -v /work/recipes/build_info/gbm-shim.* build_info/
cp -v /work/recipes/build_info/libdisplay-info-*-shim.h build_info/
cp -v /work/recipes/build_info/libdisplay-info-shim.c build_info/
cp -v /work/recipes/kwin-ios-fixes.sh build_info/
cp -v /work/recipes/kwin-ios-gpu-backend.sh build_info/
rm -rf build_info/kwin-ios-gpu
cp -Rv /work/recipes/kwin-ios-gpu build_info/
cp -v /work/build_info/iosc-gl-ent.xml build_misc/entitlements/

echo "==> staging already-built support debs into the KF6 sysroot"
stage_deb() {
  local deb=$1
  if [ -f "$deb" ]; then
    echo "   $(basename "$deb")"
    dpkg-deb -x "$deb" build_base/iphoneos-arm64-rootless/1900
  fi
}
stage_deb /out/libepoll-shim0_0.0.20240608_iphoneos-arm64.deb
stage_deb /out/libepoll-shim-dev_0.0.20240608_iphoneos-arm64.deb
stage_deb /out/libxcvt0_0.1.2_iphoneos-arm64.deb
stage_deb /out/libxcvt-dev_0.1.2_iphoneos-arm64.deb

# KWin's nested IOSurface consumer uses the GPU-fence ABI exported by the
# matched ANGLE libEGL. Do not silently link against whichever older ANGLE
# happens to be cached in the long-lived KF6 sysroot.
angle_debs=(/out/angle_*_iphoneos-arm64.deb)
if [ "${#angle_debs[@]}" -eq 0 ]; then
  echo "ERROR: no ANGLE package in /out; build ANGLE before KWin." >&2
  exit 1
fi
angle_deb="$(printf '%s\n' "${angle_debs[@]}" | sort -V | tail -n 1)"
stage_deb "$angle_deb"
if ! aarch64-apple-darwin-nm -g "${BB}/lib/angle/libEGL.dylib" |
    grep ' _xios_metal_sync_wait$' >/dev/null; then
  echo "ERROR: $(basename "$angle_deb") lacks the Xios Metal fence ABI." >&2
  exit 1
fi

mkdir -p "${BB}/usr/include/sys" "${BB}/usr/include/linux"
if [ -f "${BB}/usr/include/libepoll-shim/sys/eventfd.h" ]; then
  cp -v "${BB}/usr/include/libepoll-shim/sys/eventfd.h" "${BB}/usr/include/sys/eventfd.h"
fi
if [ -d "${BB}/usr/include/libepoll-shim/epoll-shim" ]; then
  cp -a "${BB}/usr/include/libepoll-shim/epoll-shim" "${BB}/usr/include/"
fi
cp -v /work/recipes/build_info/linux-input-event-codes.h "${BB}/usr/include/linux/input-event-codes.h"
cp -v /work/recipes/build_info/linux-input.h "${BB}/usr/include/linux/input.h"

# Normal runs rely on the fingerprint helper below so unchanged shims stay
# cached. Keep an explicit cleanup escape hatch for one-off stale volume repair.
if [ "${FORCE_KWIN_SHIM_REBUILD:-0}" = "1" ]; then
  rm -rf \
    build_work/*/*/libdrm build_stage/*/*/libdrm build_dist/*/*/libdrm build_dist/*/*/libdrm2 build_dist/*/*/libdrm-dev \
    build_work/*/*/gbm build_stage/*/*/gbm build_dist/*/*/gbm build_dist/*/*/libgbm1 build_dist/*/*/libgbm-dev \
    build_work/*/*/libdisplay-info build_stage/*/*/libdisplay-info build_dist/*/*/libdisplay-info build_dist/*/*/libdisplay-info1 build_dist/*/*/libdisplay-info-dev \
    2>/dev/null || true
fi

COMMON="MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900 NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

XIOS_CACHE_COMMON_INPUTS="/work/recipes/qt6-common.mk /work/recipes/kf6-common.mk"
source /work/recipes/xios-cache-fingerprint.sh

for t in $TARGETS; do
  echo "==> make ${t}"
  xios_cache_prepare_target "$t"
  make ${t} $COMMON -j"$(nproc)"
  xios_cache_record_target "$t"
done

echo "==> collect debs -> /out"
mkdir -p /out
for deb in \
  build_dist/iphoneos-arm64-rootless/1900/kwin/kwin_*.deb \
  build_dist/iphoneos-arm64-rootless/1900/kwin/kwin-dev_*.deb \
  build_dist/iphoneos-arm64-rootless/1900/libdrm/libdrm2_*+ios*.deb \
  build_dist/iphoneos-arm64-rootless/1900/libdrm/libdrm-dev_*+ios*.deb \
  build_dist/iphoneos-arm64-rootless/1900/gbm/libgbm1_*+ios*.deb \
  build_dist/iphoneos-arm64-rootless/1900/gbm/libgbm-dev_*+ios*.deb \
  build_dist/iphoneos-arm64-rootless/1900/libdisplay-info/libdisplay-info1_*+ios*.deb \
  build_dist/iphoneos-arm64-rootless/1900/libdisplay-info/libdisplay-info-dev_*+ios*.deb; do
  [ -e "$deb" ] && cp -v "$deb" /out/
done
echo "==> done"
