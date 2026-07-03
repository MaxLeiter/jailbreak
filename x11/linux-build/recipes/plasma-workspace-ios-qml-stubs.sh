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

breeze_components="$root/var/jb/usr/lib/qt6/qml/org/kde/breeze/components"
if [ -d "$breeze_components" ]; then
  if [ -e "$breeze_components/UserList.qml" ] && [ ! -e "$breeze_components/UserList.qml.upstream" ]; then
    cp "$breeze_components/UserList.qml" "$breeze_components/UserList.qml.upstream"
  fi

  write_file "$breeze_components/UserList.qml" \
    "// First-light iOS shim: avoid raw ListView while Mobile lockscreen starts." \
    "import QtQuick 2.15" \
    "Item {" \
    "    id: root" \
    "    property var model: null" \
    "    property int count: 0" \
    "    property int currentIndex: 0" \
    "    property string selectedUser: \"\"" \
    "    property int userItemWidth: width" \
    "    property int userItemHeight: height" \
    "    property bool constrainText: false" \
    "    property real fontSize: 12" \
    "    signal userSelected()" \
    "    implicitHeight: userItemHeight" \
    "}"
fi

digitalclock="$root/var/jb/usr/share/plasma/plasmoids/org.kde.plasma.digitalclock/contents/ui"
if [ -d "$digitalclock" ]; then
  for qml_name in CalendarView configTimeZones; do
    if [ -e "$digitalclock/$qml_name.qml" ] && [ ! -e "$digitalclock/$qml_name.qml.upstream" ]; then
      cp "$digitalclock/$qml_name.qml" "$digitalclock/$qml_name.qml.upstream"
    fi
  done

  write_file "$digitalclock/CalendarView.qml" \
    "// First-light iOS shim: avoid raw ListView in the digital clock popup." \
    "import QtQuick 2.15" \
    "Item {" \
    "    id: root" \
    "    property var appletInterface: null" \
    "    property var monthView: null" \
    "    implicitWidth: 1" \
    "    implicitHeight: 1" \
    "}"

  write_file "$digitalclock/configTimeZones.qml" \
    "// First-light iOS shim: avoid raw ListView in the digital clock config page." \
    "import QtQuick 2.15" \
    "Item {" \
    "    id: root" \
    "    property var cfg_selectedTimeZones: []" \
    "    property var cfg_lastSelectedTimezone: \"Local\"" \
    "    implicitWidth: 1" \
    "    implicitHeight: 1" \
    "}"
fi

slideshow="$root/var/jb/usr/share/plasma/wallpapers/org.kde.slideshow/contents/ui"
if [ -d "$slideshow" ]; then
  if [ -e "$slideshow/SlideshowComponent.qml" ] && [ ! -e "$slideshow/SlideshowComponent.qml.upstream" ]; then
    cp "$slideshow/SlideshowComponent.qml" "$slideshow/SlideshowComponent.qml.upstream"
  fi

  write_file "$slideshow/SlideshowComponent.qml" \
    "// First-light iOS shim: avoid raw ListView in slideshow wallpaper config." \
    "import QtQuick 2.15" \
    "Item {" \
    "    id: root" \
    "    property var cfg_Image: \"\"" \
    "    property var cfg_SlidePaths: []" \
    "    implicitWidth: 1" \
    "    implicitHeight: 1" \
    "}"
fi

notifications="$root/var/jb/usr/share/plasma/plasmoids/org.kde.plasma.notifications/contents/ui"
if [ -d "$notifications" ]; then
  if [ -e "$notifications/main.qml" ] && [ ! -e "$notifications/main.qml.upstream" ]; then
    cp "$notifications/main.qml" "$notifications/main.qml.upstream"
  fi
  if [ -e "$notifications/FullRepresentation.qml" ] && [ ! -e "$notifications/FullRepresentation.qml.upstream" ]; then
    cp "$notifications/FullRepresentation.qml" "$notifications/FullRepresentation.qml.upstream"
  fi

  write_file "$notifications/main.qml" \
    "// First-light iOS shim: avoid notification history ListView during Mobile startup." \
    "import QtQuick 2.15" \
    "import org.kde.plasma.core as PlasmaCore" \
    "import org.kde.plasma.plasmoid 2.0" \
    "" \
    "PlasmoidItem {" \
    "    id: root" \
    "    property int unreadCount: 0" \
    "    readonly property bool inhibitedOrBroken: false" \
    "    readonly property int effectiveStatus: PlasmaCore.Types.PassiveStatus" \
    "    Plasmoid.status: effectiveStatus" \
    "    Plasmoid.icon: \"notifications\"" \
    "    toolTipMainText: \"Notifications\"" \
    "    toolTipSubText: \"\"" \
    "    compactRepresentation: Item { implicitWidth: 1; implicitHeight: 1 }" \
    "    fullRepresentation: Item { implicitWidth: 1; implicitHeight: 1 }" \
    "}"

  write_file "$notifications/FullRepresentation.qml" \
    "// First-light iOS shim: avoid notification history ListView during Mobile startup." \
    "import QtQuick 2.15" \
    "Item {" \
    "    id: root" \
    "    implicitWidth: 1" \
    "    implicitHeight: 1" \
    "}"
fi
