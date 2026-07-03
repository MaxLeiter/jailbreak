#!/usr/bin/env bash
# Install first-light QML shims for Plasma PA applet views whose real UI uses
# Flickable/ListView paths that currently crash Qt Quick on iOS shell startup.
set -euo pipefail

root=${1:?usage: plasma-pa-ios-qml-stubs.sh <package-root>}

write_file() {
  local path="$1"
  shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$@" > "$path"
}

volume_ui="$root/var/jb/usr/share/plasma/plasmoids/org.kde.plasma.volume/contents/ui"
if [ -d "$volume_ui" ]; then
  if [ -e "$volume_ui/main.qml" ] && [ ! -e "$volume_ui/main.qml.upstream" ]; then
    cp "$volume_ui/main.qml" "$volume_ui/main.qml.upstream"
  fi

  write_file "$volume_ui/main.qml" \
    "// First-light iOS shim: keep the volume applet package importable while avoiding ListView/Flickable startup crashes." \
    "import QtQuick 2.15" \
    "import QtQuick.Layouts 1.15" \
    "import org.kde.plasma.core as PlasmaCore" \
    "import org.kde.plasma.plasmoid 2.0" \
    "" \
    "PlasmoidItem {" \
    "    id: root" \
    "    property bool volumeFeedback: false" \
    "    property bool globalMute: false" \
    "    property string displayName: \"Audio Volume\"" \
    "    property QtObject draggedStream: null" \
    "    Layout.minimumWidth: 1" \
    "    Layout.minimumHeight: 1" \
    "    switchWidth: 1" \
    "    switchHeight: 1" \
    "    Plasmoid.icon: \"audio-volume-muted\"" \
    "    Plasmoid.status: PlasmaCore.Types.PassiveStatus" \
    "    compactRepresentation: Item { implicitWidth: 1; implicitHeight: 1 }" \
    "    fullRepresentation: Item { implicitWidth: 1; implicitHeight: 1 }" \
    "}"
fi
