#!/usr/bin/env bash
# build-plasma-desktop.sh — cross-build first-light Plasma shell-layer packages
# on top of the completed Qt/KF6/KWin volume.
#
# This driver is deliberately narrower than the future full Plasma session. The
# default target is libplasma-package: the shared Plasma framework/theme/QML
# layer that plasma-workspace, plasma-desktop, plasma-nano, and plasma-mobile
# need before plasmashell/mobile shell testing.
set -euo pipefail

QTVER=6.6.3
BB=/work/Procursus/build_base/iphoneos-arm64-rootless/1900/var/jb
HOSTQT=/work/Procursus/build_tools/host-qt-${QTVER}

TARGETS="${TARGETS:-libplasma-package}"
SUPPORT_RECIPE_TARGETS=(
  attica
  kdeclarative
  krunner
  kded
  kstatusnotifieritem
  kunitconversion
  kparts
  knewstuff
  kwallet
  knotifyconfig
  kactivitymanagerd
  qqc2-desktop-style
  bluezqt
  kirigami-addons
  kquickcharts
  plasma5support
  pulseaudio-qt
  plasma-pa
  libkscreen
  kscreen
  systemsettings
)
SUPPORT_RECIPE_HELPERS=(
  kactivitymanagerd-ios-fixes.sh
  bluezqt-ios-fixes.sh
  plasma5support-ios-fixes.sh
  plasma-pa-ios-fixes.sh
  libkscreen-ios-fixes.sh
  kscreen-ios-fixes.sh
  systemsettings-ios-fixes.sh
  systemsettings-prune-actions.py
)
COLLECT_DEBS=(
  shared-mime-info
  libplasma
  plasma-activities-stats
  kactivitymanagerd
  plasma-workspace
  plasma-desktop
  plasma-nano
  plasma-mobile
  kf6-attica
  kf6-declarative
  kf6-runner
  kf6-kded
  kf6-statusnotifieritem
  kf6-unitconversion
  kf6-parts
  kf6-newstuff
  kf6-wallet
  kf6-notifyconfig
  kf6-qqc2-desktop-style
  kf6-bluezqt
  kf6-kirigami-addons
  kf6-kquickcharts
  plasma5support
  kf6-pulseaudio-qt
  plasma-pa
  libkscreen
  kscreen
  systemsettings
)
LOCAL_STAGE_DEBS=(
  libpulse0
  libpulse-dev
  libglib2.0-0
  libglib2.0-dev
  qt6-sensors
  qt6-sensors-dev
)

cd /work/Procursus

stage_latest_deb_from_out() {
  local pkg="$1"
  local best="" bestver="" deb ver
  for deb in "/out/${pkg}_"*.deb; do
    [ -f "$deb" ] || continue
    ver="$(dpkg-deb -f "$deb" Version 2>/dev/null || true)"
    [ -n "$ver" ] || continue
    if [ -z "$best" ] || dpkg --compare-versions "$ver" gt "$bestver"; then
      best="$deb"
      bestver="$ver"
    fi
  done
  [ -n "$best" ] || return 0
  echo "==> staging $(basename "$best") into build_base"
  dpkg-deb -x "$best" /work/Procursus/build_base/iphoneos-arm64-rootless/1900
}

# Plasma Mobile's volume applet needs PulseAudioQt, which in turn consumes the
# PulseAudio client pc files from the local audio package wave. Keep this
# self-contained so a fresh KF6 volume can build plasma-pa without a manual
# build_base surgery step.
for pkg in "${LOCAL_STAGE_DEBS[@]}"; do
  stage_latest_deb_from_out "$pkg"
done

[ -x "${HOSTQT}/libexec/moc" ] || { echo "ERROR: host Qt missing (${HOSTQT}); run build-qt.sh first." >&2; exit 1; }
[ -x "${HOSTQT}/libexec/qmlcachegen" ] || { echo "ERROR: host Qt lacks qmlcachegen; run build-qt-modules.sh first." >&2; exit 1; }
[ -x "${HOSTQT}/libexec/qtwaylandscanner" ] || { echo "ERROR: host Qt lacks qtwaylandscanner; run build-qt-modules.sh first." >&2; exit 1; }
for f in \
  usr/lib/cmake/Qt6Quick/Qt6QuickConfig.cmake \
  usr/lib/cmake/Qt6QuickControls2/Qt6QuickControls2Config.cmake \
  usr/lib/cmake/Qt6Sql/Qt6SqlConfig.cmake \
  usr/lib/cmake/Qt6Svg/Qt6SvgConfig.cmake \
  usr/lib/cmake/Qt6WaylandClient/Qt6WaylandClientConfig.cmake \
  usr/lib/cmake/KF6Archive/KF6ArchiveConfig.cmake \
  usr/lib/cmake/KF6ColorScheme/KF6ColorSchemeConfig.cmake \
  usr/lib/cmake/KF6Config/KF6ConfigConfig.cmake \
  usr/lib/cmake/KF6ConfigWidgets/KF6ConfigWidgetsConfig.cmake \
  usr/lib/cmake/KF6CoreAddons/KF6CoreAddonsConfig.cmake \
  usr/lib/cmake/KF6GlobalAccel/KF6GlobalAccelConfig.cmake \
  usr/lib/cmake/KF6GuiAddons/KF6GuiAddonsConfig.cmake \
  usr/lib/cmake/KF6I18n/KF6I18nConfig.cmake \
  usr/lib/cmake/KF6IconThemes/KF6IconThemesConfig.cmake \
  usr/lib/cmake/KF6KIO/KF6KIOConfig.cmake \
  usr/lib/cmake/KF6KirigamiPlatform/KF6KirigamiPlatformConfig.cmake \
  usr/lib/cmake/KF6KCMUtils/KF6KCMUtilsConfig.cmake \
  usr/lib/cmake/KF6Notifications/KF6NotificationsConfig.cmake \
  usr/lib/cmake/KF6Package/KF6PackageConfig.cmake \
  usr/lib/cmake/KF6Svg/KF6SvgConfig.cmake \
  usr/lib/cmake/KF6WindowSystem/KF6WindowSystemConfig.cmake \
  usr/lib/cmake/PlasmaActivities/PlasmaActivitiesConfig.cmake \
  usr/lib/cmake/PlasmaWaylandProtocols/PlasmaWaylandProtocolsConfig.cmake \
  usr/lib/pkgconfig/wayland-client.pc; do
  if [ ! -e "${BB}/${f}" ]; then
    if [ "$f" = "usr/lib/cmake/Qt6Sql/Qt6SqlConfig.cmake" ] && [ "$TARGETS" = "libplasma-package" ]; then
      echo "WARN: missing staged Qt6Sql; libplasma does not need it, but plasma-workspace support targets do." >&2
      continue
    fi
    echo "ERROR: missing staged dependency ${f}" >&2
    exit 1
  fi
done

# Current KF6 volumes may predate the KCMUtils cross-tooling path fix. The
# installed config already carries the tooling targets beside itself, but its
# cross-compile find_file() searches for KF6KCMUtils/... below the current
# directory instead of below the parent cmake directory. Repair the staged copy
# idempotently so libplasma can configure without forcing a full KF6 rebuild.
KCMUTILS_CONFIG="${BB}/usr/lib/cmake/KF6KCMUtils/KF6KCMUtilsConfig.cmake"
if [ -f "$KCMUTILS_CONFIG" ]; then
  sed -i 's|PATHS ${KF6_HOST_TOOLING} ${CMAKE_CURRENT_LIST_DIR}|PATHS ${KF6_HOST_TOOLING} ${CMAKE_CURRENT_LIST_DIR}/.. ${CMAKE_CURRENT_LIST_DIR}|' "$KCMUTILS_CONFIG"
fi
KCMUTILS_MACROS="${BB}/usr/lib/cmake/KF6KCMUtils/KF6KCMUtilsMacros.cmake"
KCM_DESKTOP_GENERATOR="${PWD}/build_tools/kcmdesktopfilegenerator-host"
cat > "$KCM_DESKTOP_GENERATOR" <<'PY'
#!/usr/bin/env python3
import json
import sys
from pathlib import Path

if len(sys.argv) != 3:
    raise SystemExit("usage: kcmdesktopfilegenerator-host <input.json> <output.desktop>")

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
metadata = json.loads(src.read_text())
kplugin = metadata.get("KPlugin", {})
program = "systemsettings" if "X-KDE-System-Settings-Parent-Category" in metadata else "kcmshell6"

lines = [
    "[Desktop Entry]",
    "Type=Application",
    "NoDisplay=true",
    "X-KDE-AliasFor=systemsettings",
    f"Exec={program} {src.stem}",
    f"Icon={kplugin.get('Icon', '')}",
]
for key in sorted(kplugin):
    if key.startswith("Name"):
        lines.append(f"{key}={kplugin[key]}")

dst.write_text("\n".join(lines) + "\n")
PY
chmod +x "$KCM_DESKTOP_GENERATOR"
if [ -f "$KCMUTILS_MACROS" ]; then
  sed -i "s|COMMAND KF6::kcmdesktopfilegenerator \${IN_FILE} \${OUT_FILE}|COMMAND ${KCM_DESKTOP_GENERATOR} \${IN_FILE} \${OUT_FILE}|" "$KCMUTILS_MACROS"
fi

apt-get update >/dev/null 2>&1 || true
apt-get install -y --no-install-recommends \
  gettext python3 gzip libboost-dev libxml2-utils libwayland-dev libwayland-bin wayland-protocols >/dev/null 2>&1 || true
if [ ! -f /usr/include/boost/range/algorithm/binary_search.hpp ]; then
  echo "ERROR: missing Boost headers; kactivitymanagerd needs libboost-dev in the build container." >&2
  exit 1
fi
mkdir -p build_tools/boost-host-include
ln -sfn /usr/include/boost build_tools/boost-host-include/boost

cat > build_tools/cc-nounused <<'EOF'
#!/usr/bin/env bash
export PATH="/root/cctools/bin:$PATH"
exec /root/cctools/bin/aarch64-apple-darwin-clang "$@" -Wno-unused-command-line-argument
EOF
cat > build_tools/cxx-nounused <<'EOF'
#!/usr/bin/env bash
export PATH="/root/cctools/bin:$PATH"
exec /root/cctools/bin/aarch64-apple-darwin-clang++ "$@" -Wno-unused-command-line-argument
EOF
chmod +x build_tools/cc-nounused build_tools/cxx-nounused

echo "==> installing Plasma Desktop recipes into makefiles/"
mkdir -p build_info build_misc/entitlements
for r in qt6-common.mk kf6-common.mk shared-mime-info.mk libplasma.mk plasma-activities-stats.mk plasma-workspace.mk plasma-desktop.mk plasma-nano.mk plasma-mobile.mk; do
  cp -v /work/recipes/$r makefiles/
done
for t in "${SUPPORT_RECIPE_TARGETS[@]}"; do
  cp -v "/work/recipes/${t}.mk" makefiles/
done
for h in "${SUPPORT_RECIPE_HELPERS[@]}"; do
  cp -v "/work/recipes/${h}" makefiles/ 2>/dev/null || true
done
cp -v /work/build_info/shared-mime-info*.control /work/build_info/shared-mime-info*.postinst /work/build_info/libplasma*.control /work/build_info/plasma-activities-stats*.control /work/build_info/kactivitymanagerd*.control /work/build_info/plasma-workspace*.control /work/build_info/plasma-desktop*.control /work/build_info/plasma-nano*.control /work/build_info/plasma-mobile*.control build_info/
for deb in "${COLLECT_DEBS[@]}"; do
  cp -v /work/build_info/${deb}*.control build_info/ 2>/dev/null || true
done
cp -v /work/build_info/iosc-gpu-client-ent.xml build_misc/entitlements/ 2>/dev/null || true

COMMON="MEMO_TARGET=iphoneos-arm64-rootless MEMO_CFVER=1900 NO_PGP=1 \
  PATH=/root/cctools/bin:/work/Procursus/build_tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  LD_LIBRARY_PATH=/root/cctools/lib \
  CC=/work/Procursus/build_tools/cc-nounused CXX=/work/Procursus/build_tools/cxx-nounused"

XIOS_CACHE_COMMON_INPUTS="/work/recipes/qt6-common.mk /work/recipes/kf6-common.mk"
source /work/recipes/xios-cache-fingerprint.sh

for t in $TARGETS; do
  echo "==> make ${t}"
  xios_cache_prepare_target "$t"
  make ${t} $COMMON -j"$(nproc)"
  xios_cache_record_target "$t"
done

echo "==> collect Plasma Desktop debs -> /out"
mkdir -p /out
for pkg in "${COLLECT_DEBS[@]}"; do
  while IFS= read -r deb; do
    [ -e "$deb" ] && cp -v "$deb" /out/
  done < <(find build_dist/iphoneos-arm64-rootless/1900 -maxdepth 2 -type f \( \
    -name "${pkg}_*.deb" -o \
    -name "${pkg}-dev_*.deb" \
  \) | sort)
done
echo "==> done"
