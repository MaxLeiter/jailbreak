#!/usr/bin/env bash
# Fast host sanity check for the first-light Plasma QML/package fix installers.
#
# This does not prove the QML will satisfy plasmashell on-device. It catches the
# packaging failures and generated-QML traps that waste a rebuild/device cycle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_dir() {
  mkdir -p "$1"
}

run_stub() {
  local name="$1"
  shift
  echo "==> $name"
  bash "$@"
}

make_dir "$TMP/libplasma/var/jb/usr/lib/qt6/qml/org/kde/plasma/components"
run_stub libplasma "$ROOT/linux-build/recipes/libplasma-ios-qml-stubs.sh" "$TMP/libplasma"

workspace_layout="$TMP/workspace/var/jb/usr/share/plasma/look-and-feel/org.kde.breeze.desktop/contents/layouts"
make_dir "$workspace_layout"
cat >"$workspace_layout/org.kde.plasma.desktop-layout.js" <<'EOF'
desktopsArray[j].wallpaperPlugin = 'org.kde.image';
EOF
run_stub plasma-workspace "$ROOT/linux-build/recipes/plasma-workspace-ios-package-fixes.sh" "$TMP/workspace"

make_dir "$TMP/plasma-pa/var/jb/usr/share/plasma/plasmoids/org.kde.plasma.volume/contents/ui"
run_stub plasma-pa "$ROOT/linux-build/recipes/plasma-pa-ios-qml-stubs.sh" "$TMP/plasma-pa"

MOBILE_QML="$TMP/mobile/var/jb/usr/lib/qt6/qml"
make_dir "$MOBILE_QML/org/kde/plasma/private/mobileshell"
make_dir "$TMP/mobile/var/jb/usr/share/plasma/plasmoids/org.kde.plasma.mobile.homescreen.folio/contents/ui/settings"
make_dir "$TMP/mobile/var/jb/usr/share/plasma/shells/org.kde.plasma.mobileshell/contents/lockscreen"
run_stub plasma-mobile "$ROOT/linux-build/recipes/plasma-mobile-ios-qml-stubs.sh" "$MOBILE_QML"

echo "==> scan generated QML"
if rg -n \
  "default property alias data|signal currentIndexChanged\\(\\)|property alias contentItem: contentItem" \
  "$TMP"; then
  echo "!! generated Plasma QML stubs contain known parser traps" >&2
  exit 1
fi

find "$TMP" -type f | wc -l | awk '{ print "checked " $1 " generated files" }'
