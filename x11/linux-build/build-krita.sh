#!/usr/bin/env bash
# build-krita.sh — cross-build Krita 6 and its reusable missing dependencies
# against the existing Qt 6/KF6 rootless-iOS sysroot.
set -euo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing" >&2; exit 1; }
. "$XIOS_TARGET_ENV"

QTVER=6.6.3
HOSTQT=/work/Procursus/build_tools/host-qt-${QTVER}
BB=$XIOS_SYSROOT
TARGETS="${TARGETS:-krita-support-package quazip-qt6-package krita-package}"
COLLECT_DEBS=(
  eigen3-dev libboost1.90-dev libxsimd-dev libimmer-dev libzug-dev liblager-dev
  libunibreak7 libunibreak-dev
  libquazip1-qt6 libquazip1-qt6-dev
  krita
)

cd /work/Procursus

[ -x "${HOSTQT}/libexec/moc" ] || { echo "ERROR: host Qt missing (${HOSTQT}); run build-qt.sh first." >&2; exit 1; }
[ -f "${BB}/usr/lib/cmake/Qt6/Qt6Config.cmake" ] || { echo "ERROR: cross qtbase not staged." >&2; exit 1; }
[ -f "${BB}/usr/lib/cmake/KF6ColorScheme/KF6ColorSchemeConfig.cmake" ] || { echo "ERROR: KF6 ColorScheme not staged." >&2; exit 1; }

apt-get update >/dev/null 2>&1 || true
apt-get install -y --no-install-recommends \
  autoconf automake libtool gettext python3 perl gzip libwayland-bin >/dev/null 2>&1 || true

cat > build_tools/cc-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
EOF
cat > build_tools/cxx-nounused <<'EOF'
#!/usr/bin/env bash
exec aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
EOF
chmod +x build_tools/cc-nounused build_tools/cxx-nounused

echo "==> installing Krita recipes and source patches"
mkdir -p build_info build_misc/entitlements
for recipe in \
  qt6-common.mk kf6-common.mk \
  krita-support.mk quazip-qt6.mk krita.mk; do
  [ -f "/work/recipes/$recipe" ] && cp -v "/work/recipes/$recipe" makefiles/
done
cp -v /work/build_info/* build_info/ 2>/dev/null || true
cp -v /work/build_info/iosc-*.xml build_misc/entitlements/ 2>/dev/null || true
for package in krita-lager krita; do
  [ -f "/work/ports/$package/patches/series" ] || continue
  bash /work/recipes/stage-port-patches.sh "$package" /work/ports build_patch
done

COMMON="$XIOS_MEMO_ARGS NO_PGP=1 \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

XIOS_CACHE_COMMON_INPUTS="/work/recipes/qt6-common.mk /work/recipes/kf6-common.mk"
source /work/recipes/xios-cache-fingerprint.sh

echo "==> staging current image-codec development packages"
for package in \
  libtiff6 libtiff-dev \
  libwebp7 libwebpdemux2 libwebpmux3 libwebp-dev \
  libharfbuzz0b libharfbuzz-dev; do
  deb="$(find /out -maxdepth 1 -type f -name "${package}_*_${XIOS_DEB_ARCH}.deb" \
    -printf '%f\t%p\n' 2>/dev/null | sort -V | tail -1 | cut -f2-)"
  if [ -z "$deb" ]; then
    echo "ERROR: Krita needs current $package in /out" >&2
    exit 1
  fi
  echo "    staging $deb"
  dpkg-deb -x "$deb" "$BB"
done

for target in $TARGETS; do
  echo "==> make ${target}"
  xios_cache_prepare_target "$target"
  make "$target" $COMMON -j"${JOBS:-4}"
  xios_cache_record_target "$target"
done

echo "==> collecting Krita wave debs -> /out"
mkdir -p /out
for package in "${COLLECT_DEBS[@]}"; do
  while IFS= read -r deb; do
    [ -e "$deb" ] && cp -v "$deb" /out/
  done < <(find "build_dist/$XIOS_TRIPLE" -maxdepth 2 -type f -name "${package}_*.deb" | sort)
done
echo "==> done"
