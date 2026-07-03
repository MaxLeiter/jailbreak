#!/usr/bin/env bash
# Install first-light QQC2 desktop-style shims for controls whose real style
# QML instantiates QQuickFlickable-derived views on iOS.
set -euo pipefail

root=${1:?usage: qqc2-desktop-style-ios-qml-stubs.sh <package-root>}

write_file() {
  local path="$1"
  shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$@" > "$path"
}

desktop="$root/var/jb/usr/lib/qt6/qml/org/kde/desktop"
if [ -d "$desktop" ]; then
  for qml_name in Menu ComboBox DialogButtonBox TabBar; do
    if [ -e "$desktop/$qml_name.qml" ] && [ ! -e "$desktop/$qml_name.qml.upstream" ]; then
      cp "$desktop/$qml_name.qml" "$desktop/$qml_name.qml.upstream"
    fi
  done

  write_file "$desktop/Menu.qml" \
    "// First-light iOS shim: avoid raw ListView menu contentItem during shell startup." \
    "import QtQuick 2.15" \
    "Item {" \
    "    id: root" \
    "    property var model: null" \
    "    property Component delegate: null" \
    "    property bool modal: false" \
    "    property int closePolicy: 0" \
    "    default property alias contentData: _contentItem.data" \
    "    signal opened()" \
    "    signal closed()" \
    "    signal aboutToShow()" \
    "    signal aboutToHide()" \
    "    Item { id: _contentItem; anchors.fill: parent }" \
    "    function open() { visible = true; aboutToShow(); opened() }" \
    "    function close() { visible = false; aboutToHide(); closed() }" \
    "    function popup() { open() }" \
    "}"

  write_file "$desktop/ComboBox.qml" \
    "// First-light iOS shim: avoid raw ListView popup during shell startup." \
    "import QtQuick 2.15" \
    "Item {" \
    "    id: root" \
    "    property var model: null" \
    "    property Component delegate: null" \
    "    property int currentIndex: -1" \
    "    property string currentText: \"\"" \
    "    property string textRole: \"\"" \
    "    property bool editable: false" \
    "    property bool flat: false" \
    "    property bool down: false" \
    "    property alias contentItem: _contentItem" \
    "    signal activated(int index)" \
    "    signal highlighted(int index)" \
    "    implicitWidth: 1" \
    "    implicitHeight: 1" \
    "    Item { id: _contentItem; anchors.fill: parent }" \
    "    function popup() {}" \
    "    function incrementCurrentIndex() { currentIndex += 1 }" \
    "    function decrementCurrentIndex() { currentIndex = Math.max(-1, currentIndex - 1) }" \
    "}"

  write_file "$desktop/DialogButtonBox.qml" \
    "// First-light iOS shim: avoid raw ListView button layout during shell startup." \
    "import QtQuick 2.15" \
    "Item {" \
    "    id: root" \
    "    property int standardButtons: 0" \
    "    property int position: 0" \
    "    property alias contentItem: _contentItem" \
    "    default property alias contentData: _contentItem.data" \
    "    signal accepted()" \
    "    signal rejected()" \
    "    signal clicked(var button)" \
    "    implicitWidth: 1" \
    "    implicitHeight: 1" \
    "    Item { id: _contentItem; anchors.fill: parent }" \
    "}"

  write_file "$desktop/TabBar.qml" \
    "// First-light iOS shim: avoid raw ListView tab layout during shell startup." \
    "import QtQuick 2.15" \
    "Item {" \
    "    id: root" \
    "    property int currentIndex: -1" \
    "    property int count: 0" \
    "    property alias contentItem: _contentItem" \
    "    default property alias contentData: _contentItem.data" \
    "    implicitWidth: 1" \
    "    implicitHeight: 1" \
    "    Item { id: _contentItem; anchors.fill: parent }" \
    "}"
fi
