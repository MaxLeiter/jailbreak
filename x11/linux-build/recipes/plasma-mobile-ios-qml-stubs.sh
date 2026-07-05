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
  "import org.kde.plasma.private.mobileshell as MobileShell" \
  "QtObject {" \
  "    id: root" \
  "    property bool networkingEnabled: true" \
  "    function refresh() {" \
  "        var probe = MobileShell.ShellUtil.runCommand(\"test -e /var/run/resolv.conf -o -e /etc/resolv.conf -o -S /var/jb/tmp/pulse/native; echo \$?\", 500)" \
  "        networkingEnabled = probe.length === 0 || probe === \"0\"" \
  "    }" \
  "    Component.onCompleted: refresh()" \
  "    Timer { interval: 30000; running: true; repeat: true; onTriggered: root.refresh() }" \
  "}"
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
  "    property string wifiSSID: \"iPad\"" \
  "}"
write_file "$nm/ConnectionIcon.qml" \
  "import QtQuick 2.15" \
  "import org.kde.plasma.private.mobileshell as MobileShell" \
  "QtObject {" \
  "    id: root" \
  "    property string connectionIcon: \"network-wireless-signal-excellent\"" \
  "    property bool connecting: false" \
  "    function refresh() {" \
  "        var probe = MobileShell.ShellUtil.runCommand(\"test -e /var/run/resolv.conf -o -e /etc/resolv.conf -o -S /var/jb/tmp/pulse/native; echo \$?\", 500)" \
  "        connectionIcon = (probe.length === 0 || probe === \"0\") ? \"network-wireless-signal-excellent\" : \"network-disconnect\"" \
  "    }" \
  "    Component.onCompleted: refresh()" \
  "    Timer { interval: 30000; running: true; repeat: true; onTriggered: root.refresh() }" \
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
  "import org.kde.plasma.private.mobileshell as MobileShell" \
  "QtObject {" \
  "    id: root" \
  "    readonly property string backlight: \"/var/jb/sys/class/backlight/xios_backlight\"" \
  "    property int brightness: 50" \
  "    property int brightnessMax: 1000" \
  "    property bool refreshing: false" \
  "    function readInt(name, fallbackValue) {" \
  "        var value = parseInt(MobileShell.ShellUtil.readTextFile(backlight + \"/\" + name))" \
  "        return isNaN(value) ? fallbackValue : value" \
  "    }" \
  "    function refresh() {" \
  "        refreshing = true" \
  "        brightnessMax = Math.max(1, readInt(\"max_brightness\", brightnessMax))" \
  "        brightness = Math.max(1, Math.min(brightnessMax, readInt(\"brightness\", brightness)))" \
  "        refreshing = false" \
  "    }" \
  "    onBrightnessChanged: if (!refreshing) MobileShell.ShellUtil.writeTextFile(backlight + \"/brightness\", Math.round(brightness).toString())" \
  "    Component.onCompleted: refresh()" \
  "    Timer { interval: 10000; running: true; repeat: true; onTriggered: root.refresh() }" \
  "}"

wallpaper="$qml/org/kde/plasma/private/mobileshell/wallpaperimageplugin"
mkdir -p "$wallpaper"
write_file "$wallpaper/qmldir" \
  "module org.kde.plasma.private.mobileshell.wallpaperimageplugin" \
  "singleton WallpaperPlugin 1.0 WallpaperPlugin.qml"
write_file "$wallpaper/WallpaperPlugin.qml" \
  "pragma Singleton" \
  "import QtQuick 2.15" \
  "import org.kde.plasma.private.mobileshell as MobileShell" \
  "QtObject {" \
  "    id: root" \
  "    readonly property string configPath: \"/var/mobile/Library/Preferences/com.max.iosc-wallpaper\"" \
  "    readonly property string fallbackPath: \"/var/mobile/Library/Preferences/com.max.iosc-wallpaper.jpg\"" \
  "    property string homescreenWallpaperPath: \"\"" \
  "    property string lockscreenWallpaperPath: \"\"" \
  "    property string homescreenWallpaperPlugin: \"org.kde.image\"" \
  "    property string homescreenWallpaperPluginSource: \"\"" \
  "    property string lockscreenWallpaperPlugin: \"org.kde.image\"" \
  "    property string lockscreenWallpaperPluginSource: \"\"" \
  "    property var homescreenConfiguration: ({})" \
  "    property var lockscreenConfiguration: ({})" \
  "    property var wallpaperPluginModel: []" \
  "    function setHomescreenWallpaper(path) { homescreenWallpaperPath = path; saveHomescreenSettings() }" \
  "    function setLockscreenWallpaper(path) { lockscreenWallpaperPath = path; saveLockscreenSettings() }" \
  "    function saveHomescreenSettings() { if (homescreenWallpaperPath.length > 0) MobileShell.ShellUtil.writeTextFile(configPath, homescreenWallpaperPath) }" \
  "    function saveLockscreenSettings() { if (lockscreenWallpaperPath.length > 0) MobileShell.ShellUtil.writeTextFile(configPath, lockscreenWallpaperPath) }" \
  "    function loadHomescreenSettings() { homescreenWallpaperPath = MobileShell.ShellUtil.readTextFile(configPath); if (homescreenWallpaperPath.length === 0) homescreenWallpaperPath = fallbackPath }" \
  "    function loadLockscreenSettings() { lockscreenWallpaperPath = MobileShell.ShellUtil.readTextFile(configPath); if (lockscreenWallpaperPath.length === 0) lockscreenWallpaperPath = fallbackPath }" \
  "    Component.onCompleted: { loadHomescreenSettings(); loadLockscreenSettings() }" \
  "}"

mobileshell="$qml/org/kde/plasma/private/mobileshell"
mkdir -p "$mobileshell"
if [ -e "$mobileshell/GridView.qml" ] && [ ! -e "$mobileshell/GridView.qml.upstream" ]; then
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
  "    property int currentIndex: -1" \
  "    property int cellWidth: width" \
  "    property int cellHeight: 96" \
  "    property int flow: 0" \
  "    property int orientation: 0" \
  "    property int layoutDirection: Qt.LeftToRight" \
  "    property int verticalLayoutDirection: 0" \
  "    property int boundsBehavior: 0" \
  "    property int boundsMovement: 0" \
  "    property int flickableDirection: 0" \
  "    property int highlightRangeMode: 0" \
  "    property int headerPositioning: 0" \
  "    property int snapMode: 0" \
  "    property real cacheBuffer: 0" \
  "    property real flickDeceleration: 0" \
  "    property real pressDelay: 0" \
  "    property bool reuseItems: false" \
  "    property bool keyNavigationWraps: false" \
  "    property bool keyNavigationEnabled: true" \
  "    property bool interactive: false" \
  "    property bool dragging: false" \
  "    property bool atYBeginning: true" \
  "    property bool atYEnd: true" \
  "    property bool moving: false" \
  "    property real contentX: 0" \
  "    property real contentY: 0" \
  "    property real contentWidth: width" \
  "    property real contentHeight: height" \
  "    property real leftMargin: 0" \
  "    property real rightMargin: 0" \
  "    property real topMargin: 0" \
  "    property real bottomMargin: 0" \
  "    property real displayMarginBeginning: 0" \
  "    property real displayMarginEnd: 0" \
  "    property real preferredHighlightBegin: 0" \
  "    property real preferredHighlightEnd: 0" \
  "    property real highlightMoveDuration: 0" \
  "    property real highlightResizeDuration: 0" \
  "    property real maximumFlickVelocity: 0" \
  "    property real spacing: 0" \
  "    property Component highlight: null" \
  "    property var add: null" \
  "    property var displaced: null" \
  "    property var header: null" \
  "    property bool highlightFollowsCurrentItem: true" \
  "    readonly property Item currentItem: null" \
  "    property var topEdgeCallback: null" \
  "    property var bottomEdgeCallback: null" \
  "    property var leftEdgeCallback: null" \
  "    property var rightEdgeCallback: null" \
  "    signal movementStarted()" \
  "    signal movementEnded()" \
  "    signal flickStarted()" \
  "    signal flickEnded()" \
  "    function itemAtIndex(index) { return null }" \
  "    function indexAt(x, y) { return -1 }" \
  "    function flick(xVelocity, yVelocity) {}" \
  "    function positionViewAtIndex(index, mode) {}" \
  "    function resizeContent(width, height, center) { contentWidth = width; contentHeight = height }" \
  "    function returnToBounds() {}" \
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
  "    property int cellWidth: width" \
  "    property int cellHeight: 96" \
  "    property int flow: 0" \
  "    property int orientation: 0" \
  "    property int boundsBehavior: 0" \
  "    property int boundsMovement: 0" \
  "    property int flickableDirection: 0" \
  "    property int highlightRangeMode: 0" \
  "    property int headerPositioning: 0" \
  "    property int snapMode: 0" \
  "    property bool interactive: false" \
  "    property bool dragging: false" \
  "    property bool moving: false" \
  "    property bool reuseItems: false" \
  "    property bool keyNavigationWraps: false" \
  "    property bool keyNavigationEnabled: true" \
  "    property bool atYBeginning: true" \
  "    property bool atYEnd: true" \
  "    property real cacheBuffer: 0" \
  "    property real flickDeceleration: 0" \
  "    property real pressDelay: 0" \
  "    property real contentX: 0" \
  "    property real contentY: 0" \
  "    property real contentWidth: width" \
  "    property real contentHeight: height" \
  "    property real topMargin: 0" \
  "    property real bottomMargin: 0" \
  "    property real leftMargin: 0" \
  "    property real rightMargin: 0" \
  "    property real displayMarginBeginning: 0" \
  "    property real displayMarginEnd: 0" \
  "    property real preferredHighlightBegin: 0" \
  "    property real preferredHighlightEnd: 0" \
  "    property real highlightMoveDuration: 0" \
  "    property real highlightResizeDuration: 0" \
  "    property real maximumFlickVelocity: 0" \
  "    property real spacing: 0" \
  "    property var add: null" \
  "    property var displaced: null" \
  "    property var header: null" \
  "    property bool highlightFollowsCurrentItem: true" \
  "    readonly property Item currentItem: null" \
  "    signal movementStarted()" \
  "    signal movementEnded()" \
  "    signal flickStarted()" \
  "    signal flickEnded()" \
  "    function itemAtIndex(index) { return null }" \
  "    function indexAt(x, y) { return -1 }" \
  "    function flick(xVelocity, yVelocity) {}" \
  "    function positionViewAtIndex(index, mode) {}" \
  "    function resizeContent(width, height, center) { contentWidth = width; contentHeight = height }" \
  "    function returnToBounds() {}" \
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
  "    property int boundsBehavior: 0" \
  "    property int boundsMovement: 0" \
  "    property int flickableDirection: 0" \
  "    property int orientation: 0" \
  "    property real contentX: 0" \
  "    property real contentY: 0" \
  "    property real contentWidth: width" \
  "    property real contentHeight: height" \
  "    property real flickDeceleration: 0" \
  "    property real pressDelay: 0" \
  "    property real maximumFlickVelocity: 0" \
  "    property real topMargin: 0" \
  "    property real bottomMargin: 0" \
  "    property real leftMargin: 0" \
  "    property real rightMargin: 0" \
  "    signal movementStarted()" \
  "    signal movementEnded()" \
  "    signal flickStarted()" \
  "    signal flickEnded()" \
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
    "    property var notificationModel" \
    "    property var notificationSettings" \
    "    property var notificationsWidget: ({" \
    "        doNotDisturbModeEnabled: false," \
    "        toggleDoNotDisturbMode: function() { this.doNotDisturbModeEnabled = !this.doNotDisturbModeEnabled }" \
    "    })" \
    "    property var restrictedPermissions" \
    "    property var historyModel" \
    "    property var pendingNotificationWithAction" \
    "    property var textField" \
    "    property var view" \
    "    property var statusNotifierSource" \
    "    property Component content" \
    "    default property alias contentChildren: contentItem.data" \
    "    property int edge: Qt.BottomEdge" \
    "    property int notificationModelType: 0" \
    "    property int historyModelType: 0" \
    "    property int columns: 1" \
    "    property int columnCount: columns" \
    "    property int minimizedColumns: 1" \
    "    property int quickSettingsCount: 0" \
    "    property int rowCount: 0" \
    "    property int pageSize: 0" \
    "    property int previewCharIndex: -1" \
    "    property int animationDuration: 0" \
    "    property int direction: Qt.BottomEdge" \
    "    property string queryString: \"\"" \
    "    property string backgroundColor: \"transparent\"" \
    "    property string pluginName: \"\"" \
    "    property string pinLabel: \"\"" \
    "    property string prevText: \"\"" \
    "    property color colorScopeColor: \"transparent\"" \
    "    property color color: \"transparent\"" \
    "    property color headerTextColor: \"transparent\"" \
    "    property color headerTextInactiveColor: \"transparent\"" \
    "    property bool active: false" \
    "    property bool expanded: false" \
    "    property bool shown: false" \
    "    property bool dragging: false" \
    "    property bool opened: shown" \
    "    property bool opening: false" \
    "    property bool isOpen: shown" \
    "    property bool horizontal: false" \
    "    property bool showSecondRow: false" \
    "    property bool showDropShadow: false" \
    "    property bool disableSystemTray: false" \
    "    property bool actionsRequireUnlock: false" \
    "    property bool openToPinnedMode: false" \
    "    property bool doNotDisturbModeEnabled: false" \
    "    property bool hasNotifications: false" \
    "    property bool listOverflowing: false" \
    "    property bool externalEdit: false" \
    "    property bool isPinMode: false" \
    "    property bool keypadOpen: false" \
    "    property bool showChar: false" \
    "    property bool showFullApplet: false" \
    "    property bool suppressActiveClose: false" \
    "    property bool isCurrent: false" \
    "    property bool isOnLargeScreen: false" \
    "    property bool showTime: true" \
    "    property real availableHeight: height" \
    "    property real topMargin: 0" \
    "    property real bottomMargin: 0" \
    "    property real leftMargin: 0" \
    "    property real rightMargin: 0" \
    "    property real offset: 0" \
    "    property real oldOffset: 0" \
    "    property real oldMouseY: 0" \
    "    property real offsetDist: 0" \
    "    property real offsetHeight: 0" \
    "    property real totalOffsetDist: 0" \
    "    property real largePortraitThreshold: 0" \
    "    property real maximizedQuickSettingsOffset: 0" \
    "    property real minimizedQuickSettingsOffset: 0" \
    "    property real minimizedViewProgress: 0" \
    "    property real fullViewProgress: 0" \
    "    property real closedContentY: 0" \
    "    property real oldContentY: 0" \
    "    property real openFactor: 0" \
    "    property real openedContentY: 0" \
    "    property real contentHeight: height" \
    "    property real padding: 0" \
    "    property real horizontalMargin: 0" \
    "    property real intendedCellWidth: 0" \
    "    property real maxCellWidth: 0" \
    "    property real zoomScale: 1" \
    "    property real columnWidth: 0" \
    "    property real fullHeight: height" \
    "    property real intendedColumnWidth: 0" \
    "    property real intendedMinimizedColumnWidth: 0" \
    "    property real minimizedColumnWidth: 0" \
    "    property real minimizedRowHeight: 0" \
    "    property real rowHeight: 0" \
    "    property real dotWidth: 0" \
    "    property real intendedWidth: width" \
    "    property real minWidthHeight: Math.min(width, height)" \
    "    property real offsetRatio: 0" \
    "    property real opacityValue: opacity" \
    "    property real contentImplicitHeight: implicitHeight" \
    "    property real elementSpacing: 0" \
    "    property real smallerTextPixelSize: 12" \
    "    property real textPixelSize: 14" \
    "    property var lockScreenState" \
    "    property int mode: 0" \
    "    Item { id: contentItem; anchors.fill: parent }" \
    "    signal closed()" \
    "    signal requestedClose()" \
    "    signal requestClose()" \
    "    signal drawerClosed()" \
    "    signal drawerOpened()" \
    "    signal permissionsRequested()" \
    "    signal runPendingNotificationAction()" \
    "    signal actionTriggered()" \
    "    signal activated()" \
    "    signal backgroundClicked()" \
    "    signal unlockRequested()" \
    "    signal wallpaperSettingsRequested()" \
    "    function open() { shown = true }" \
    "    function close() { shown = false; closed(); requestedClose(); requestClose() }" \
    "    function closeImmediately() { close() }" \
    "    function toggle() { shown = !shown; if (!shown) { backgroundClicked() } }" \
    "    function expand() { expanded = true }" \
    "    function cancelAnimations() {}" \
    "    function updateState() {}" \
    "    function startSwipe() {}" \
    "    function updateOffset(value) { offset = value }" \
    "    function endSwipe() {}" \
    "    function activateNextAction() {}" \
    "    function clearField() {}" \
    "    function requestFocus() { forceActiveFocus() }" \
    "    function startGesture() {}" \
    "    function updateGestureOffset(value) { offset = value }" \
    "    function endGesture() {}" \
    "    function getTrackName() { return \"\" }" \
    "    function clearHistory() {}" \
    "    function isRowExpanded(row) { return false }" \
    "    function openNotificationSettings() {}" \
    "    function runPendingAction() {}" \
    "    function setGroupExpanded(group, expanded) {}" \
    "    function toggleDoNotDisturbMode() { doNotDisturbModeEnabled = !doNotDisturbModeEnabled }" \
    "    function applyMinMax(value) { return value }" \
    "    function onRunPendingNotificationAction() {}" \
    "    function onOpenedChanged() {}" \
    "    function resetSwipeView() {}" \
    "    function showOverlay() { shown = true }" \
    "    function backspace() {}" \
    "    function clear() {}" \
    "    function enter() {}" \
    "    function keyPress(key, text, modifiers) {}" \
    "    function onPasswordChanged() {}" \
    "    function onUnlockFailed() {}" \
    "    function onUnlockSucceeded() {}" \
    "}"
}
for qml_name in \
  ActionDrawer \
  ActionDrawerOpenSurface \
  AudioApplet \
  KRunnerScreen \
  KRunnerWidget \
  LandscapeContentContainer \
  MediaControlsWidget \
  NotificationsWidget \
  PortraitContentContainer \
  QuickSettings \
  QuickSettingsPanel \
  StatusBar \
  VolumeOSD \
  WallpaperSelector; do
  if [ -e "$mobileshell/$qml_name.qml" ] && [ ! -e "$mobileshell/$qml_name.qml.upstream" ]; then
    cp "$mobileshell/$qml_name.qml" "$mobileshell/$qml_name.qml.upstream"
  fi
  write_mobile_item_stub "$qml_name"
done

for qml_name in VolumeOSDProvider VolumeOSDProviderLoader; do
  if [ -e "$mobileshell/$qml_name.qml" ] && [ ! -e "$mobileshell/$qml_name.qml.upstream" ]; then
    cp "$mobileshell/$qml_name.qml" "$mobileshell/$qml_name.qml.upstream"
  fi
done
write_file "$mobileshell/VolumeOSDProvider.qml" \
  "// First-light iOS shim: avoid loading the real volume provider while AudioInfo/VolumeOSD are stubbed." \
  "import QtQuick 2.15" \
  "QtObject {" \
  "    id: root" \
  "    function showVolumeOverlay() {}" \
  "}"
write_file "$mobileshell/VolumeOSDProviderLoader.qml" \
  "// First-light iOS shim: keep MobileShell.VolumeOSDProviderLoader importable without recursive module loading." \
  "pragma Singleton" \
  "import QtQuick 2.15" \
  "QtObject {" \
  "    id: root" \
  "    property bool active: false" \
  "    function load() { active = true }" \
  "}"

write_file "$mobileshell/ClockText.qml" \
  "// First-light iOS shim: avoid Plasma5Support time dataengine during Mobile startup." \
  "import QtQuick 2.15" \
  "import QtQuick.Controls 2.15" \
  "Label {" \
  "    id: root" \
  "    property var source" \
  "    property bool is24HourTime: true" \
  "    text: Qt.formatTime(new Date(), is24HourTime ? \"h:mm\" : \"h:mm ap\")" \
  "    verticalAlignment: Text.AlignVCenter" \
  "    Timer {" \
  "        interval: 60000" \
  "        running: true" \
  "        repeat: true" \
  "        onTriggered: root.text = Qt.formatTime(new Date(), root.is24HourTime ? \"h:mm\" : \"h:mm ap\")" \
  "    }" \
  "}"

write_file "$mobileshell/BatteryInfo.qml" \
  "// iOS provider: use xios-fhs synthetic power_supply files instead of Plasma5Support powermanagement." \
  "pragma Singleton" \
  "import QtQuick 2.15" \
  "QtObject {" \
  "    id: root" \
  "    readonly property string sysRoot: \"/var/jb/sys\"" \
  "    property bool isVisible: true" \
  "    property int percent: 100" \
  "    property bool pluggedIn: false" \
  "    function readText(path, fallbackValue) {" \
  "        var text = ShellUtil.readTextFile(path)" \
  "        return text.length > 0 ? text : fallbackValue" \
  "    }" \
  "    function readInt(path, fallbackValue) {" \
  "        var value = parseInt(readText(path, \"\"))" \
  "        return isNaN(value) ? fallbackValue : value" \
  "    }" \
  "    function refresh() {" \
  "        var present = readInt(sysRoot + \"/class/power_supply/BAT0/present\", 1)" \
  "        var status = readText(sysRoot + \"/class/power_supply/BAT0/status\", \"Unknown\").toLowerCase()" \
  "        isVisible = present !== 0" \
  "        percent = Math.max(0, Math.min(100, readInt(sysRoot + \"/class/power_supply/BAT0/capacity\", percent)))" \
  "        pluggedIn = readInt(sysRoot + \"/class/power_supply/AC0/online\", 0) !== 0 || status.indexOf(\"charging\") !== -1" \
  "    }" \
  "    Component.onCompleted: refresh()" \
  "    Timer { interval: 30000; running: true; repeat: true; onTriggered: root.refresh() }" \
  "}"

write_file "$mobileshell/AudioInfo.qml" \
  "// iOS provider: use the existing Xios PulseAudio bridge through bounded pactl probes." \
  "pragma Singleton" \
  "import QtQuick 2.15" \
  "QtObject {" \
  "    id: root" \
  "    readonly property bool isVisible: true" \
  "    readonly property string icon: iconName(volumeValue, muted)" \
  "    readonly property int maxVolumePercent: 100" \
  "    readonly property int maxVolumeValue: 100" \
  "    readonly property int volumeStep: 5" \
  "    property int volumeValue: 0" \
  "    property bool muted: false" \
  "    property var paSinkModel: null" \
  "    signal volumeChanged()" \
  "    function pulse(command) {" \
  "        return ShellUtil.runCommand(\". /var/jb/etc/profile.d/xios-pulse.sh 2>/dev/null; xios_pulse_start >/dev/null 2>&1; \" + command, 1500)" \
  "    }" \
  "    function refresh() {" \
  "        var volume = pulse(\"pactl get-sink-volume xios 2>/dev/null | sed -n 's/.*\\\\/ *\\\\([0-9][0-9]*\\\\)%.*/\\\\1/p' | head -1\")" \
  "        var value = parseInt(volume)" \
  "        if (!isNaN(value)) volumeValue = Math.max(0, Math.min(maxVolumePercent, value))" \
  "        muted = pulse(\"pactl get-sink-mute xios 2>/dev/null | awk '{print \$2}'\") === \"yes\"" \
  "    }" \
  "    function increaseVolume() { pulse(\"pactl set-sink-volume xios +5%\"); refresh(); volumeChanged() }" \
  "    function decreaseVolume() { pulse(\"pactl set-sink-volume xios -5%\"); refresh(); volumeChanged() }" \
  "    function muteVolume() { pulse(\"pactl set-sink-mute xios toggle\"); refresh(); volumeChanged() }" \
  "    function iconName(volume, isMuted, prefix) {" \
  "        var base = prefix || \"audio-volume\"" \
  "        if (isMuted || volume <= 0) return base + \"-muted\"" \
  "        if (volume <= 25) return base + \"-low\"" \
  "        if (volume <= 75) return base + \"-medium\"" \
  "        return base + \"-high\"" \
  "    }" \
  "    function volumePercent(volume, max) { return Math.round(volume) }" \
  "    Component.onCompleted: refresh()" \
  "    Timer { interval: 10000; running: true; repeat: true; onTriggered: root.refresh() }" \
  "}"

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
    "    property int columns: 1" \
    "    property real horizontalMargin: 0" \
    "    property real intendedCellWidth: 0" \
    "    property real maxCellWidth: 0" \
    "    property real zoomScale: 1" \
    "    property string pluginName: \"\"" \
    "    signal requestClose()" \
    "    onClicked: root.requestClose()" \
    "}"
fi

folio_ui="$qml/../../../share/plasma/plasmoids/org.kde.plasma.mobile.homescreen.folio/contents/ui"
if [ -d "$folio_ui" ]; then
  if [ -e "$folio_ui/main.qml" ] && [ ! -e "$folio_ui/main.qml.upstream" ]; then
    cp "$folio_ui/main.qml" "$folio_ui/main.qml.upstream"
  fi
  write_file "$folio_ui/main.qml" \
    "// First-light iOS shim: defer the real Folio homescreen until Qt Quick views are stable." \
    "import QtQuick 2.15" \
    "import org.kde.plasma.plasmoid 2.0" \
    "ContainmentItem {" \
    "    id: root" \
    "    Item { anchors.fill: parent }" \
    "}"
fi

halcyon_ui="$qml/../../../share/plasma/plasmoids/org.kde.plasma.mobile.homescreen.halcyon/contents/ui"
if [ -d "$halcyon_ui" ]; then
  if [ -e "$halcyon_ui/main.qml" ] && [ ! -e "$halcyon_ui/main.qml.upstream" ]; then
    cp "$halcyon_ui/main.qml" "$halcyon_ui/main.qml.upstream"
  fi
  write_file "$halcyon_ui/main.qml" \
    "// First-light iOS shim: defer the real Halcyon homescreen until Qt Quick views are stable." \
    "import QtQuick 2.15" \
    "import org.kde.plasma.plasmoid 2.0" \
    "ContainmentItem {" \
    "    id: root" \
    "    Item { anchors.fill: parent }" \
    "}"
fi

views="$qml/../../../share/plasma/shells/org.kde.plasma.mobileshell/contents/views"
if [ -e "$views/Panel.qml" ]; then
  python3 - "$views/Panel.qml" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
needle = "    Connections {\n        target: containment\n        function onActivated() {"
if needle in text and "ignoreUnknownSignals: true" not in text:
    text = text.replace(
        needle,
        "    Connections {\n        target: containment\n        ignoreUnknownSignals: true\n        function onActivated() {",
        1,
    )
    path.write_text(text)
PY
fi

lockscreen="$qml/../../../share/plasma/shells/org.kde.plasma.mobileshell/contents/lockscreen"
if [ -d "$lockscreen" ]; then
  if [ -e "$lockscreen/PasswordBar.qml" ] && [ ! -e "$lockscreen/PasswordBar.qml.upstream" ]; then
    cp "$lockscreen/PasswordBar.qml" "$lockscreen/PasswordBar.qml.upstream"
  fi
  write_file "$lockscreen/PasswordBar.qml" \
    "// First-light iOS shim: avoid raw ListView during lockscreen setup." \
    "import QtQuick 2.15" \
    "import QtQuick.Controls 2.15" \
    "Item {" \
    "    id: root" \
    "    property string password: \"\"" \
    "    property string placeholderText: \"\"" \
    "    property bool keypadOpen: false" \
    "    property bool showChar: false" \
    "    property bool isPinMode: false" \
    "    property bool externalEdit: false" \
    "    property int previewCharIndex: -1" \
    "    property real dotWidth: 0" \
    "    property color color: \"transparent\"" \
    "    property color headerTextColor: \"transparent\"" \
    "    property color headerTextInactiveColor: \"transparent\"" \
    "    property var lockScreenState" \
    "    property var textField" \
    "    property string pinLabel: \"\"" \
    "    property string prevText: \"\"" \
    "    signal accepted(string password)" \
    "    function backspace() {}" \
    "    function clear() { password = \"\" }" \
    "    function enter() { accepted(password) }" \
    "    function keyPress(key, text, modifiers) {}" \
    "    function onPasswordChanged() {}" \
    "    function onUnlockFailed() {}" \
    "    function onUnlockSucceeded() {}" \
    "    TextField {" \
    "        anchors.centerIn: parent" \
    "        width: Math.min(parent.width, 420)" \
    "        placeholderText: root.placeholderText" \
    "        echoMode: TextInput.Password" \
    "        onAccepted: root.accepted(text)" \
    "    }" \
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

# org.kde.kirigamiaddons.* is provided by the real kf6-kirigami-addons package.
# Keep Plasma Mobile from owning fallback files in that namespace so dpkg can
# install the real package beside it without path collisions.
