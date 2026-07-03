#!/usr/bin/env bash
# Install first-light QML shims for Plasma Mobile imports whose real backends
# depend on Linux services or later UI support packages.
set -euo pipefail

qml=${1:?usage: plasma-mobile-ios-qml-stubs.sh <qt6-qml-dir>}

write_file() {
  local path="$1"
  shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$@" > "$path"
}

mm="$qml/org/kde/plasma/mm"
mkdir -p "$mm"
write_file "$mm/qmldir" \
  "module org.kde.plasma.mm" \
  "singleton SignalIndicator 1.0 SignalIndicator.qml"
write_file "$mm/SignalIndicator.qml" \
  "pragma Singleton" \
  "import QtQuick 2.15" \
  "QtObject {" \
  "    property int strength: 0" \
  "    property string name: \"\"" \
  "    property bool modemAvailable: false" \
  "    property bool simLocked: false" \
  "    property bool simEmpty: true" \
  "    property bool mobileDataSupported: false" \
  "    property bool mobileDataEnabled: false" \
  "    property bool needsAPNAdded: false" \
  "    property var profiles: []" \
  "    property string activeConnectionUni: \"\"" \
  "    function refreshProfiles() {}" \
  "    function activateProfile(connectionUni) {}" \
  "    function addProfile(name, apn, username, password, networkType) {}" \
  "    function removeProfile(connectionUni) {}" \
  "    function updateProfile(connectionUni, name, apn, username, password, networkType) {}" \
  "}"

nm="$qml/org/kde/plasma/networkmanagement"
mkdir -p "$nm"
write_file "$nm/qmldir" \
  "module org.kde.plasma.networkmanagement" \
  "singleton Configuration 1.0 Configuration.qml" \
  "NetworkStatus 1.0 NetworkStatus.qml" \
  "NetworkModel 1.0 NetworkModel.qml" \
  "Handler 1.0 Handler.qml" \
  "WirelessStatus 1.0 WirelessStatus.qml" \
  "ConnectionIcon 1.0 ConnectionIcon.qml" \
  "EnabledConnections 1.0 EnabledConnections.qml"
write_file "$nm/Configuration.qml" \
  "pragma Singleton" \
  "import QtQuick 2.15" \
  "QtObject { property bool airplaneModeEnabled: false }"
write_file "$nm/NetworkStatus.qml" \
  "import QtQuick 2.15" \
  "QtObject { property bool networkingEnabled: true }"
write_file "$nm/NetworkModel.qml" \
  "import QtQuick 2.15" \
  "ListModel {}"
write_file "$nm/Handler.qml" \
  "import QtQuick 2.15" \
  "QtObject {" \
  "    function enableAirplaneMode(enabled) {}" \
  "    function enableWireless(enabled) {}" \
  "    function createHotspot() {}" \
  "    function stopHotspot() {}" \
  "}"
write_file "$nm/WirelessStatus.qml" \
  "import QtQuick 2.15" \
  "QtObject {" \
  "    property string hotspotSSID: \"\"" \
  "    property string wifiSSID: \"\"" \
  "}"
write_file "$nm/ConnectionIcon.qml" \
  "import QtQuick 2.15" \
  "QtObject {" \
  "    property string connectionIcon: \"network-wireless-signal-excellent\"" \
  "    property bool connecting: false" \
  "}"
write_file "$nm/EnabledConnections.qml" \
  "import QtQuick 2.15" \
  "QtObject { property bool wirelessEnabled: true }"

brightness="$qml/org/kde/plasma/private/brightnesscontrolplugin"
mkdir -p "$brightness"
write_file "$brightness/qmldir" \
  "module org.kde.plasma.private.brightnesscontrolplugin" \
  "ScreenBrightnessControl 1.0 ScreenBrightnessControl.qml"
write_file "$brightness/ScreenBrightnessControl.qml" \
  "import QtQuick 2.15" \
  "QtObject {" \
  "    property int brightness: 50" \
  "    property int brightnessMax: 100" \
  "}"

wallpaper="$qml/org/kde/plasma/private/mobileshell/wallpaperimageplugin"
mkdir -p "$wallpaper"
write_file "$wallpaper/qmldir" \
  "module org.kde.plasma.private.mobileshell.wallpaperimageplugin" \
  "singleton WallpaperPlugin 1.0 WallpaperPlugin.qml"
write_file "$wallpaper/WallpaperPlugin.qml" \
  "pragma Singleton" \
  "import QtQuick 2.15" \
  "QtObject {" \
  "    property string homescreenWallpaperPath: \"\"" \
  "    property string lockscreenWallpaperPath: \"\"" \
  "    property string homescreenWallpaperPlugin: \"org.kde.image\"" \
  "    property string homescreenWallpaperPluginSource: \"\"" \
  "    property string lockscreenWallpaperPlugin: \"org.kde.image\"" \
  "    property string lockscreenWallpaperPluginSource: \"\"" \
  "    property var homescreenConfiguration: ({})" \
  "    property var lockscreenConfiguration: ({})" \
  "    property var wallpaperPluginModel: []" \
  "    function setHomescreenWallpaper(path) { homescreenWallpaperPath = path }" \
  "    function setLockscreenWallpaper(path) { lockscreenWallpaperPath = path }" \
  "    function saveHomescreenSettings() {}" \
  "    function saveLockscreenSettings() {}" \
  "    function loadHomescreenSettings() {}" \
  "    function loadLockscreenSettings() {}" \
  "}"

mobileshell="$qml/org/kde/plasma/private/mobileshell"
mkdir -p "$mobileshell"
if [ -e "$mobileshell/GridView.qml" ]; then
  cp "$mobileshell/GridView.qml" "$mobileshell/GridView.qml.upstream"
fi
write_file "$mobileshell/GridView.qml" \
  "// First-light iOS shim: QQuickFlickable-derived views currently SIGBUS during Mobile startup." \
  "import QtQuick 2.15" \
  "Item {" \
  "    id: root" \
  "    property var model: null" \
  "    property Component delegate: null" \
  "    property int count: 0" \
  "    property int cellWidth: width" \
  "    property int cellHeight: 96" \
  "    property real cacheBuffer: 0" \
  "    property bool reuseItems: false" \
  "    property bool interactive: false" \
  "    property bool dragging: false" \
  "    property bool atYBeginning: true" \
  "    property real contentY: 0" \
  "    property real contentHeight: height" \
  "    property real leftMargin: 0" \
  "    property real rightMargin: 0" \
  "    property Component highlight: null" \
  "    readonly property Item currentItem: null" \
  "    property var topEdgeCallback: null" \
  "    property var bottomEdgeCallback: null" \
  "    property var leftEdgeCallback: null" \
  "    property var rightEdgeCallback: null" \
  "    function indexAt(x, y) { return -1 }" \
  "    function flick(xVelocity, yVelocity) {}" \
  "    function positionViewAtIndex(index, mode) {}" \
  "}"

for qml_name in ListView Flickable; do
  if [ -e "$mobileshell/$qml_name.qml" ] && [ ! -e "$mobileshell/$qml_name.qml.upstream" ]; then
    cp "$mobileshell/$qml_name.qml" "$mobileshell/$qml_name.qml.upstream"
  fi
done
write_file "$mobileshell/ListView.qml" \
  "// First-light iOS shim: QQuickFlickable-derived views currently crash during Mobile startup." \
  "import QtQuick 2.15" \
  "Item {" \
  "    id: root" \
  "    property var model: null" \
  "    property Component delegate: null" \
  "    property Component highlight: null" \
  "    property int count: 0" \
  "    property int currentIndex: -1" \
  "    property bool interactive: false" \
  "    property bool dragging: false" \
  "    property bool moving: false" \
  "    property bool atYBeginning: true" \
  "    property bool atYEnd: true" \
  "    property real contentY: 0" \
  "    property real contentHeight: height" \
  "    property real topMargin: 0" \
  "    property real bottomMargin: 0" \
  "    readonly property Item currentItem: null" \
  "    function itemAtIndex(index) { return null }" \
  "    function indexAt(x, y) { return -1 }" \
  "    function flick(xVelocity, yVelocity) {}" \
  "    function positionViewAtIndex(index, mode) {}" \
  "}"
write_file "$mobileshell/Flickable.qml" \
  "// First-light iOS shim: QQuickFlickable currently crashes during Mobile startup." \
  "import QtQuick 2.15" \
  "Item {" \
  "    id: root" \
  "    default property alias content: contentItem.data" \
  "    property bool interactive: false" \
  "    property bool dragging: false" \
  "    property bool moving: false" \
  "    property bool atYBeginning: true" \
  "    property bool atYEnd: true" \
  "    property real contentX: 0" \
  "    property real contentY: 0" \
  "    property real contentWidth: width" \
  "    property real contentHeight: height" \
  "    property real topMargin: 0" \
  "    property real bottomMargin: 0" \
  "    property real leftMargin: 0" \
  "    property real rightMargin: 0" \
  "    Item { id: contentItem; anchors.fill: parent }" \
  "    function flick(xVelocity, yVelocity) {}" \
  "    function resizeContent(width, height, center) { contentWidth = width; contentHeight = height }" \
  "    function returnToBounds() {}" \
  "}"

write_mobile_item_stub() {
  local name="$1"
  write_file "$mobileshell/$name.qml" \
    "// First-light iOS shim: defer the real $name until Qt Quick Flickable/ListView is stable." \
    "import QtQuick 2.15" \
    "Item {" \
    "    id: root" \
    "    enum Mode { Pages, Grid, List }" \
    "    property var shell" \
    "    property var state" \
    "    property var window" \
    "    property var screen" \
    "    property var panel" \
    "    property var containment" \
    "    property var plasmoid" \
    "    property var model" \
    "    property var sourceModel" \
    "    property var currentPlayer" \
    "    property var popup" \
    "    property var homeScreen" \
    "    property var folio" \
    "    property var actionDrawer" \
    "    property int edge: Qt.BottomEdge" \
    "    property string queryString: \"\"" \
    "    property string backgroundColor: \"transparent\"" \
    "    property bool active: false" \
    "    property bool expanded: false" \
    "    property bool shown: false" \
    "    property bool horizontal: false" \
    "    property bool showSecondRow: false" \
    "    property bool showDropShadow: false" \
    "    property bool disableSystemTray: false" \
    "    property real availableHeight: height" \
    "    property real bottomMargin: 0" \
    "    property real leftMargin: 0" \
    "    property real rightMargin: 0" \
    "    property real minimizedViewProgress: 0" \
    "    property real fullViewProgress: 0" \
    "    property int mode: 0" \
    "    signal closed()" \
    "    signal requestedClose()" \
    "    signal requestClose()" \
    "    signal wallpaperSettingsRequested()" \
    "    function open() { shown = true }" \
    "    function close() { shown = false; closed(); requestedClose(); requestClose() }" \
    "    function toggle() { shown = !shown }" \
    "}"
}
for qml_name in \
  AudioApplet \
  KRunnerScreen \
  KRunnerWidget \
  MediaControlsWidget \
  NotificationsWidget \
  QuickSettings \
  VolumeOSD \
  WallpaperSelector; do
  if [ -e "$mobileshell/$qml_name.qml" ]; then
    cp "$mobileshell/$qml_name.qml" "$mobileshell/$qml_name.qml.upstream"
  fi
  write_mobile_item_stub "$qml_name"
done

folio_settings="$qml/../../../share/plasma/plasmoids/org.kde.plasma.mobile.homescreen.folio/contents/ui/settings"
if [ -d "$folio_settings" ]; then
  if [ -e "$folio_settings/AppletListViewer.qml" ] && [ ! -e "$folio_settings/AppletListViewer.qml.upstream" ]; then
    cp "$folio_settings/AppletListViewer.qml" "$folio_settings/AppletListViewer.qml.upstream"
  fi
  write_file "$folio_settings/AppletListViewer.qml" \
    "// First-light iOS shim: defer the widget picker GridView until Qt Quick views are stable." \
    "import QtQuick 2.15" \
    "MouseArea {" \
    "    id: root" \
    "    property var folio" \
    "    property var homeScreen" \
    "    signal requestClose()" \
    "    onClicked: root.requestClose()" \
    "}"
fi

mpris="$qml/org/kde/plasma/private/mpris"
mkdir -p "$mpris"
write_file "$mpris/qmldir" \
  "module org.kde.plasma.private.mpris" \
  "Mpris2Model 1.0 Mpris2Model.qml" \
  "singleton PlaybackStatus 1.0 PlaybackStatus.qml"
write_file "$mpris/Mpris2Model.qml" \
  "import QtQuick 2.15" \
  "ListModel {" \
  "    property int currentIndex: 0" \
  "    property var currentPlayer: ({ Previous: function(){}, Next: function(){}, PlayPause: function(){} })" \
  "}"
write_file "$mpris/PlaybackStatus.qml" \
  "pragma Singleton" \
  "import QtQuick 2.15" \
  "QtObject {" \
  "    enum State { Playing, Paused, Stopped }" \
  "}"

milou="$qml/org/kde/milou"
mkdir -p "$milou"
write_file "$milou/qmldir" \
  "module org.kde.milou" \
  "ResultsListView 1.0 ResultsListView.qml"
write_file "$milou/ResultsListView.qml" \
  "import QtQuick 2.15" \
  "Item {" \
  "    property string queryString: \"\"" \
  "    property var model: null" \
  "    property Component delegate: null" \
  "    property Component highlight: null" \
  "    property real contentHeight: 0" \
  "    property int currentIndex: -1" \
  "    signal activated()" \
  "    signal updateQueryString(string text, int cursorPosition)" \
  "    function runCurrentIndex() {}" \
  "    function runAction(index) {}" \
  "}"

form="$qml/org/kde/kirigamiaddons/formcard"
mkdir -p "$form"
write_file "$form/qmldir" \
  "module org.kde.kirigamiaddons.formcard" \
  "FormHeader 1.0 FormHeader.qml" \
  "FormCard 1.0 FormCard.qml" \
  "FormSpinBoxDelegate 1.0 FormSpinBoxDelegate.qml" \
  "FormSwitchDelegate 1.0 FormSwitchDelegate.qml" \
  "FormDelegateSeparator 1.0 FormDelegateSeparator.qml" \
  "FormComboBoxDelegate 1.0 FormComboBoxDelegate.qml" \
  "FormSectionText 1.0 FormSectionText.qml" \
  "FormButtonDelegate 1.0 FormButtonDelegate.qml"
write_file "$form/FormHeader.qml" \
  "import QtQuick 2.15" \
  "import QtQuick.Controls 2.15" \
  "Label {" \
  "    property string title: \"\"" \
  "    text: title" \
  "    font.bold: true" \
  "    topPadding: 12" \
  "    bottomPadding: 6" \
  "}"
write_file "$form/FormCard.qml" \
  "import QtQuick 2.15" \
  "import QtQuick.Layouts 1.15" \
  "ColumnLayout {" \
  "    spacing: 0" \
  "    Layout.fillWidth: true" \
  "}"
write_file "$form/FormSpinBoxDelegate.qml" \
  "import QtQuick 2.15" \
  "import QtQuick.Controls 2.15" \
  "import QtQuick.Layouts 1.15" \
  "RowLayout {" \
  "    id: root" \
  "    property string label: \"\"" \
  "    property alias from: spin.from" \
  "    property alias to: spin.to" \
  "    property alias value: spin.value" \
  "    Layout.fillWidth: true" \
  "    Label { text: root.label; Layout.fillWidth: true }" \
  "    SpinBox { id: spin }" \
  "}"
write_file "$form/FormSwitchDelegate.qml" \
  "import QtQuick.Controls 2.15" \
  "SwitchDelegate { }"
write_file "$form/FormDelegateSeparator.qml" \
  "import QtQuick 2.15" \
  "Rectangle {" \
  "    property var above" \
  "    property var below" \
  "    implicitHeight: 1" \
  "    color: \"transparent\"" \
  "}"
write_file "$form/FormComboBoxDelegate.qml" \
  "import QtQuick.Controls 2.15" \
  "ComboBox { property string text: \"\" }"
write_file "$form/FormSectionText.qml" \
  "import QtQuick 2.15" \
  "import QtQuick.Controls 2.15" \
  "Label { wrapMode: Text.WordWrap }"
write_file "$form/FormButtonDelegate.qml" \
  "import QtQuick.Controls 2.15" \
  "Button { }"
