#!/usr/bin/env bash
# build-okular.sh — cross-build Okular and its missing support packages on the
# Qt/KF6 volume.
set -euo pipefail

QTVER=6.6.3
HOSTQT=/work/Procursus/build_tools/host-qt-${QTVER}
BB=/work/Procursus/build_base/iphoneos-arm64-rootless/1900/var/jb
TARGETS="${TARGETS:-poppler-qt6-package threadweaver-package okular-package}"
COLLECT_DEBS=(libpoppler-qt6 kf6-threadweaver okular)

cd /work/Procursus

[ -x "${HOSTQT}/libexec/moc" ] || { echo "ERROR: host Qt missing (${HOSTQT}); run build-qt.sh first." >&2; exit 1; }
[ -f "${BB}/usr/lib/cmake/Qt6/Qt6Config.cmake" ] || { echo "ERROR: cross qtbase not staged." >&2; exit 1; }
[ -f "${BB}/usr/lib/cmake/Qt6Svg/Qt6SvgConfig.cmake" ] || { echo "ERROR: qtsvg not staged." >&2; exit 1; }
[ -f "${BB}/usr/lib/cmake/Qt6PrintSupport/Qt6PrintSupportConfig.cmake" ] || { echo "ERROR: QtPrintSupport not staged." >&2; exit 1; }
[ -f "${BB}/usr/lib/cmake/KF6Parts/KF6PartsConfig.cmake" ] || { echo "ERROR: KF6Parts not staged." >&2; exit 1; }

apt-get update >/dev/null 2>&1 || true
apt-get install -y --no-install-recommends \
  gettext python3 gzip libwayland-bin >/dev/null 2>&1 || true

cat > build_tools/cc-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
EOF
cat > build_tools/cxx-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
EOF
chmod +x build_tools/cc-nounused build_tools/cxx-nounused

echo "==> installing Okular recipes into makefiles/"
mkdir -p build_info build_misc/entitlements
for r in qt6-common.mk kf6-common.mk poppler-qt6.mk threadweaver.mk okular.mk; do
  cp -v /work/recipes/$r makefiles/
done
cp -v /work/build_info/* build_info/ 2>/dev/null || true
cp -v /work/build_info/iosc-*.xml build_misc/entitlements/ 2>/dev/null || true

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

echo "==> collect Okular debs -> /out"
mkdir -p /out
for pkg in "${COLLECT_DEBS[@]}"; do
  while IFS= read -r deb; do
    [ -e "$deb" ] && cp -v "$deb" /out/
  done < <(find build_dist/iphoneos-arm64-rootless/1900 -maxdepth 2 -type f \( \
    -name "${pkg}_*.deb" -o \
    -name "${pkg}-3_*.deb" -o \
    -name "${pkg}-dev_*.deb" \
  \) | sort)
done
echo "==> done"
