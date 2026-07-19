#!/usr/bin/env bash
# Fast host sanity check for the active Plasma iOS package fixes and QML providers.
#
# This does not prove the QML will satisfy plasmashell on-device. It catches
# packaging failures and generated-QML parser traps before a rebuild/device cycle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_fix() {
  local name="$1"
  shift
  echo "==> $name"
  bash "$@"
}

workspace_layout="$TMP/workspace/var/jb/usr/share/plasma/look-and-feel/org.kde.breeze.desktop/contents/layouts"
mkdir -p "$workspace_layout"
printf '%s\n' "desktopsArray[j].wallpaperPlugin = 'org.kde.image';" \
  >"$workspace_layout/org.kde.plasma.desktop-layout.js"
run_fix plasma-workspace "$ROOT/linux-build/recipes/plasma-workspace-ios-package-fixes.sh" "$TMP/workspace"

MOBILE_QML="$TMP/mobile/var/jb/usr/lib/qt6/qml"
mkdir -p "$MOBILE_QML/org/kde/plasma/private/mobileshell"
mkdir -p "$TMP/mobile/var/jb/usr/share/plasma/plasmoids/org.kde.plasma.mobile.homescreen.folio/contents/ui/settings"
mkdir -p "$TMP/mobile/var/jb/usr/share/plasma/shells/org.kde.plasma.mobileshell/contents/lockscreen"
run_fix plasma-mobile "$ROOT/linux-build/recipes/plasma-mobile-ios-qml-stubs.sh" "$MOBILE_QML"

echo "==> scan generated QML"
if rg -n \
  "default property alias data|signal currentIndexChanged\\(\\)|property alias contentItem: contentItem" \
  "$TMP"; then
  echo "!! generated Plasma iOS QML contains known parser traps" >&2
  exit 1
fi

find "$TMP" -type f | wc -l | awk '{ print "checked " $1 " generated files" }'
