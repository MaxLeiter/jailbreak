#!/usr/bin/env bash
# Install first-light Plasma Workspace QML shims for views that currently crash
# Qt Quick's Flickable-derived constructors on iOS during shell startup.
set -euo pipefail

root=${1:?usage: plasma-workspace-ios-qml-stubs.sh <package-root>}

write_file() {
  local path="$1"
  shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$@" > "$path"
}

systemtray="$root/var/jb/usr/share/plasma/plasmoids/org.kde.plasma.private.systemtray/contents/ui"
if [ -d "$systemtray" ]; then
  for qml_name in main HiddenItemsView; do
    if [ -e "$systemtray/$qml_name.qml" ] && [ ! -e "$systemtray/$qml_name.qml.upstream" ]; then
      cp "$systemtray/$qml_name.qml" "$systemtray/$qml_name.qml.upstream"
    fi
  done

  write_file "$systemtray/main.qml" \
    "// First-light iOS shim: avoid raw GridView while Qt Quick Flickable startup is unstable." \
    "import QtQuick 2.15" \
    "import QtQuick.Layouts 1.15" \
    "import org.kde.plasma.core as PlasmaCore" \
    "import org.kde.plasma.plasmoid 2.0" \
    "" \
    "ContainmentItem {" \
    "    id: root" \
    "    readonly property bool vertical: Plasmoid.formFactor === PlasmaCore.Types.Vertical" \
    "    readonly property var systemTrayState: null" \
    "    readonly property int itemSize: 1" \
    "    readonly property Item visibleLayout: placeholder" \
    "    readonly property Item hiddenLayout: placeholder" \
    "    readonly property bool oneRowOrColumn: true" \
    "    Layout.minimumWidth: 1" \
    "    Layout.minimumHeight: 1" \
    "    Item { id: placeholder; anchors.fill: parent }" \
    "}"

  write_file "$systemtray/HiddenItemsView.qml" \
    "// First-light iOS shim: avoid raw GridView while Qt Quick Flickable startup is unstable." \
    "import QtQuick 2.15" \
    "Item {" \
    "    id: root" \
    "    property alias layout: hiddenTasks" \
    "    Item {" \
    "        id: hiddenTasks" \
    "        anchors.fill: parent" \
    "        property int currentIndex: -1" \
    "        property int count: 0" \
    "    }" \
    "}"
fi
