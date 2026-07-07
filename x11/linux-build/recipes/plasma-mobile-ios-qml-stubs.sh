#!/usr/bin/env bash
# Install Xios-backed QML providers for Plasma Mobile imports whose upstream
# Linux backends do not exist on iOS.
set -euo pipefail

qml=${1:?usage: plasma-mobile-ios-qml-stubs.sh <qt6-qml-dir>}

write_file() {
  local path="$1"
  shift
  mkdir -p "$(dirname "$path")"
  printf '%s\n' "$@" > "$path"
}

write_block() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path"
}

restore_upstream_file() {
  local path="$1"
  if [ -e "$path.upstream" ]; then
    cp "$path.upstream" "$path"
  fi
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
  "    property Timer refreshTimer: Timer { interval: 30000; running: true; repeat: true; onTriggered: root.refresh() }" \
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
  "    property Timer refreshTimer: Timer { interval: 30000; running: true; repeat: true; onTriggered: root.refresh() }" \
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
  "    property Timer refreshTimer: Timer { interval: 10000; running: true; repeat: true; onTriggered: root.refresh() }" \
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

mobile_layout="$qml/../../../share/plasma/shells/org.kde.plasma.mobileshell/contents/layout.js"
if [ -f "$mobile_layout" ]; then
  python3 - "$mobile_layout" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
old = '    desktopsArray[j].wallpaperPlugin = "org.kde.image";\n'
new = '''    desktopsArray[j].wallpaperPlugin = "org.kde.image";
    desktopsArray[j].currentConfigGroup = ["Wallpaper", "org.kde.image", "General"];
    desktopsArray[j].writeConfig("Image", "file:///var/jb/usr/share/backgrounds/xios/xios-default.jpg");
    desktopsArray[j].writeConfig("PreviewImage", "file:///var/jb/usr/share/backgrounds/xios/xios-default.jpg");
    desktopsArray[j].writeConfig("FillMode", 2);
'''
if old in text and "xios-default.jpg" not in text:
    text = text.replace(old, new, 1)
path.write_text(text)
PY
fi

folio_app_drawer="$qml/../../../share/plasma/plasmoids/org.kde.plasma.mobile.homescreen.folio/contents/ui/AppDrawer.qml"
if [ -f "$folio_app_drawer" ]; then
  python3 - "$folio_app_drawer" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
old = """            opacity: 0
            headerHeight: root.headerHeight
"""
new = """            // xios-folio-drawer-grid-visible: the parent drawer already gates opacity.
            opacity: 1
            headerHeight: root.headerHeight
"""
if old in text and "xios-folio-drawer-grid-visible" not in text:
    text = text.replace(old, new, 1)
path.write_text(text)
PY
fi

folio_app_drawer_grid="$qml/../../../share/plasma/plasmoids/org.kde.plasma.mobile.homescreen.folio/contents/ui/AppDrawerGrid.qml"
if [ -f "$folio_app_drawer_grid" ]; then
  python3 - "$folio_app_drawer_grid" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
old = """    readonly property int reservedSpaceForLabel: folio.HomeScreenState.pageDelegateLabelHeight
    readonly property real effectiveContentWidth: width - leftMargin - rightMargin
    readonly property real horizontalMargin: Math.round(width * 0.05)

    leftMargin: horizontalMargin
    rightMargin: horizontalMargin

    cellWidth: effectiveContentWidth / Math.min(Math.floor(effectiveContentWidth / (folio.FolioSettings.delegateIconSize + Kirigami.Units.largeSpacing * 3.5)), 8)
    cellHeight: cellWidth + reservedSpaceForLabel
"""
new = """    readonly property int reservedSpaceForLabel: folio.HomeScreenState.pageDelegateLabelHeight
    readonly property bool xiosTabletLayout: width >= Kirigami.Units.gridUnit * 40
    readonly property int xiosMaxColumns: width >= height ? 7 : 5
    readonly property real xiosMinCellWidth: Math.max(folio.FolioSettings.delegateIconSize + Kirigami.Units.largeSpacing * 4, Kirigami.Units.gridUnit * 8)
    readonly property real xiosBaseMargin: Math.round(width * 0.05)
    readonly property int xiosUpstreamColumns: Math.max(1, Math.min(Math.floor(Math.max(1, width - xiosBaseMargin * 2) / (folio.FolioSettings.delegateIconSize + Kirigami.Units.largeSpacing * 3.5)), 8))
    readonly property int xiosTabletColumns: Math.max(1, Math.min(xiosMaxColumns, Math.floor(Math.max(1, width - Kirigami.Units.gridUnit * 2) / xiosMinCellWidth)))
    readonly property int xiosActiveColumns: xiosTabletLayout ? xiosTabletColumns : xiosUpstreamColumns
    readonly property real xiosContentWidth: xiosTabletLayout ? xiosActiveColumns * xiosMinCellWidth : width - xiosBaseMargin * 2
    readonly property real effectiveContentWidth: width - leftMargin - rightMargin
    readonly property real horizontalMargin: Math.round(xiosTabletLayout ? Math.max(xiosBaseMargin, (width - xiosContentWidth) / 2) : xiosBaseMargin)

    leftMargin: horizontalMargin
    rightMargin: horizontalMargin

    cellWidth: effectiveContentWidth / xiosActiveColumns
    cellHeight: cellWidth + reservedSpaceForLabel
"""
if old in text and "xiosTabletLayout" not in text:
    text = text.replace(old, new, 1)
if "xiosTabletLayout" in text:
    text = text.replace(
        "    readonly property int columns: Math.floor(effectiveContentWidth / cellWidth)\n",
        "    readonly property int columns: xiosActiveColumns\n",
        1,
    )
path.write_text(text)
PY
fi

mobileshell="$qml/org/kde/plasma/private/mobileshell"
mkdir -p "$mobileshell"
if [ -e "$mobileshell/GridView.qml" ] && [ ! -e "$mobileshell/GridView.qml.upstream" ]; then
  cp "$mobileshell/GridView.qml" "$mobileshell/GridView.qml.upstream"
fi
write_file "$mobileshell/GridView.qml" \
  "import QtQuick 2.15 as QtQuick" \
  "" \
  "QtQuick.GridView {" \
  "    id: root" \
  "    // xios-mobile-real-gridview: real drawer delegates, with iOS edge-hook placeholders." \
  "    property var topEdgeCallback: null" \
  "    property var bottomEdgeCallback: null" \
  "    property var leftEdgeCallback: null" \
  "    property var rightEdgeCallback: null" \
  "}"

for qml_name in ListView Flickable; do
  if [ -e "$mobileshell/$qml_name.qml" ] && [ ! -e "$mobileshell/$qml_name.qml.upstream" ]; then
    cp "$mobileshell/$qml_name.qml" "$mobileshell/$qml_name.qml.upstream"
  fi
done
write_file "$mobileshell/ListView.qml" \
  "import QtQuick 2.15 as QtQuick" \
  "" \
  "QtQuick.ListView {" \
  "    id: root" \
  "    // xios-mobile-real-listview: the Qt Quick iOS Flickable root fix is in qtdeclarative." \
  "    flickDeceleration: 1500" \
  "    maximumFlickVelocity: 5000" \
  "    property int currentIndex: -1" \
  "    onActiveFocusChanged: if (!activeFocus) currentIndex = -1" \
  "    onDraggingChanged: if (dragging) currentIndex = -1" \
  "}"
write_file "$mobileshell/Flickable.qml" \
  "import QtQuick 2.15 as QtQuick" \
  "" \
  "QtQuick.Flickable {" \
  "    id: root" \
  "    // xios-mobile-real-flickable: keep upstream behavior with deterministic iOS physics." \
  "    flickDeceleration: 1500" \
  "    maximumFlickVelocity: 5000" \
  "}"

write_file "$mobileshell/ClockText.qml" \
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
  "    property Timer refreshTimer: Timer { interval: 30000; running: true; repeat: true; onTriggered: root.refresh() }" \
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
  "    property Timer refreshTimer: Timer { interval: 10000; running: true; repeat: true; onTriggered: root.refresh() }" \
  "}"

# Active Xios/iOS service providers for Mobile status and quick settings.
write_block "$mm/SignalIndicator.qml" <<'QML'
pragma Singleton
import QtQuick 2.15

QtObject {
    id: root
    property int strength: 0
    property string name: ""
    property bool modemAvailable: false
    property bool simLocked: false
    property bool simEmpty: true
    property bool mobileDataSupported: false
    property bool mobileDataEnabled: false
    property bool needsAPNAdded: false
    property var profiles: []
    property string activeConnectionUni: ""
    function refreshProfiles() {}
    function activateProfile(connectionUni) {}
    function addProfile(name, apn, username, password, networkType) {}
    function removeProfile(connectionUni) {}
    function updateProfile(connectionUni, name, apn, username, password, networkType) {}
}
QML

write_block "$nm/NetworkStatus.qml" <<'QML'
import QtQuick 2.15
import org.kde.plasma.private.mobileshell as MobileShell

QtObject {
    id: root
    property bool networkingEnabled: false
    property bool limitedConnectivity: false
    property string status: networkingEnabled ? "Connected" : "Disconnected"
    function refresh() {
        networkingEnabled = MobileShell.ShellUtil.networkReachable()
        limitedConnectivity = false
    }
    Component.onCompleted: refresh()
    property Timer refreshTimer: Timer { interval: 30000; running: true; repeat: true; onTriggered: root.refresh() }
}
QML

write_block "$nm/ConnectionIcon.qml" <<'QML'
import QtQuick 2.15
import org.kde.plasma.private.mobileshell as MobileShell

QtObject {
    id: root
    property string connectionIcon: "network-disconnect"
    property bool connecting: false
    function refresh() {
        connectionIcon = MobileShell.ShellUtil.networkReachable()
            ? (MobileShell.ShellUtil.networkIsCellular() ? "network-mobile-100" : "network-wireless-signal-excellent")
            : "network-disconnect"
    }
    Component.onCompleted: refresh()
    property Timer refreshTimer: Timer { interval: 30000; running: true; repeat: true; onTriggered: root.refresh() }
}
QML

write_block "$nm/WirelessStatus.qml" <<'QML'
import QtQuick 2.15
import org.kde.plasma.private.mobileshell as MobileShell

QtObject {
    property string hotspotSSID: ""
    property string wifiSSID: MobileShell.ShellUtil.networkReachable() && !MobileShell.ShellUtil.networkIsCellular() ? "Wi-Fi" : ""
}
QML

write_block "$wallpaper/WallpaperPlugin.qml" <<'QML'
pragma Singleton
import QtQuick 2.15
import org.kde.plasma.private.mobileshell as MobileShell

QtObject {
    id: root
    readonly property string configPath: "/var/mobile/Library/Preferences/com.max.iosc-wallpaper"
    readonly property string nativeWallpaperPath: "/var/mobile/Library/Preferences/com.max.iosc-wallpaper.jpg"
    readonly property string defaultWallpaperPath: "/var/jb/usr/share/backgrounds/xios/xios-default.jpg"
    property string homescreenWallpaperPath: defaultWallpaperPath
    property string lockscreenWallpaperPath: homescreenWallpaperPath
    property string homescreenWallpaperPlugin: "org.kde.image"
    property string homescreenWallpaperPluginSource: "org.kde.image"
    property string lockscreenWallpaperPlugin: "org.kde.image"
    property string lockscreenWallpaperPluginSource: "org.kde.image"
    property var homescreenConfiguration: ({})
    property var lockscreenConfiguration: ({})
    property var wallpaperPluginModel: []

    function normalize(path) {
        if (!path || path.length === 0) {
            return defaultWallpaperPath
        }
        if (path.indexOf("file://") === 0) {
            return path.substring(7)
        }
        return path
    }

    function plasmaUrl(path) {
        var normalized = normalize(path)
        return normalized.indexOf("file://") === 0 ? normalized : "file://" + normalized
    }

    function refreshConfiguration() {
        homescreenConfiguration = ({ "Image": plasmaUrl(homescreenWallpaperPath), "PreviewImage": plasmaUrl(homescreenWallpaperPath), "FillMode": 2 })
        lockscreenConfiguration = ({ "Image": plasmaUrl(lockscreenWallpaperPath), "PreviewImage": plasmaUrl(lockscreenWallpaperPath), "FillMode": 2 })
    }

    function setHomescreenWallpaper(path) {
        homescreenWallpaperPath = normalize(path)
        saveHomescreenSettings()
        refreshConfiguration()
    }

    function setLockscreenWallpaper(path) {
        lockscreenWallpaperPath = normalize(path)
        saveLockscreenSettings()
        refreshConfiguration()
    }

    function saveHomescreenSettings() {
        if (homescreenWallpaperPath.length > 0) {
            MobileShell.ShellUtil.writeTextFile(configPath, homescreenWallpaperPath)
        }
    }

    function saveLockscreenSettings() {
        if (lockscreenWallpaperPath.length > 0) {
            MobileShell.ShellUtil.writeTextFile(configPath, lockscreenWallpaperPath)
        }
    }

    function loadHomescreenSettings() {
        var saved = MobileShell.ShellUtil.readTextFile(configPath)
        homescreenWallpaperPath = saved.length > 0 ? normalize(saved) : defaultWallpaperPath
        lockscreenWallpaperPath = homescreenWallpaperPath
        refreshConfiguration()
    }

    function loadLockscreenSettings() {
        loadHomescreenSettings()
    }

    Component.onCompleted: loadHomescreenSettings()
}
QML

write_block "$mobileshell/StatusBar.qml" <<'QML'
import QtQuick 2.15
import QtQuick.Layouts 1.15
import org.kde.kirigami 2.20 as Kirigami
import org.kde.plasma.components 3.0 as PlasmaComponents

Item {
    id: root
    property bool showDropShadow: false
    property color backgroundColor: "transparent"
    property bool showSecondRow: false
    property bool showTime: true
    property bool disableSystemTray: false
    property color colorScopeColor: Kirigami.Theme.backgroundColor
    property var statusNotifierSource: null
    readonly property real textPixelSize: 11
    readonly property real smallerTextPixelSize: 9
    readonly property real elementSpacing: Kirigami.Units.smallSpacing * 1.5
    property date now: new Date()
    Timer { interval: 1000; running: true; repeat: true; onTriggered: root.now = new Date() }
    Rectangle { anchors.fill: parent; color: root.backgroundColor }
    ColumnLayout {
        anchors.fill: parent
        anchors.leftMargin: Kirigami.Units.smallSpacing * 2
        anchors.rightMargin: Kirigami.Units.smallSpacing * 2
        spacing: 0
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: root.elementSpacing
            PlasmaComponents.Label {
                visible: root.showTime
                text: Qt.formatTime(root.now, ShellUtil.isSystem24HourFormat ? "h:mm" : "h:mm ap")
                color: Kirigami.Theme.textColor
                font.pixelSize: root.textPixelSize
            }
            Item { Layout.fillWidth: true }
            Kirigami.Icon {
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Layout.preferredWidth
                source: ShellUtil.networkReachable()
                    ? (ShellUtil.networkIsCellular() ? "network-mobile-100" : "network-wireless-signal-excellent")
                    : "network-disconnect"
            }
            Kirigami.Icon {
                visible: AudioInfo.isVisible
                Layout.preferredWidth: Kirigami.Units.iconSizes.small
                Layout.preferredHeight: Layout.preferredWidth
                source: AudioInfo.icon
            }
            RowLayout {
                visible: BatteryInfo.isVisible
                spacing: Kirigami.Units.smallSpacing / 2
                Kirigami.Icon {
                    Layout.preferredWidth: Kirigami.Units.iconSizes.small
                    Layout.preferredHeight: Layout.preferredWidth
                    source: BatteryInfo.icon
                }
                PlasmaComponents.Label {
                    text: i18n("%1%", BatteryInfo.percent)
                    color: Kirigami.Theme.textColor
                    font.pixelSize: root.textPixelSize
                }
            }
        }
        RowLayout {
            visible: root.showSecondRow
            Layout.fillWidth: true
            PlasmaComponents.Label {
                text: Qt.formatDate(root.now, "ddd. MMMM d")
                color: Kirigami.Theme.disabledTextColor
                font.pixelSize: root.smallerTextPixelSize
            }
            Item { Layout.fillWidth: true }
            PlasmaComponents.Label {
                text: ShellUtil.networkReachable()
                    ? (ShellUtil.networkIsCellular() ? i18n("Cellular") : i18n("Wi-Fi"))
                    : i18n("Offline")
                color: Kirigami.Theme.disabledTextColor
                font.pixelSize: root.smallerTextPixelSize
            }
        }
    }
}
QML

write_block "$mobileshell/QuickSettings.qml" <<'QML'
import QtQuick 2.15
import QtQuick.Layouts 1.15
import org.kde.kirigami 2.20 as Kirigami
import org.kde.plasma.components 3.0 as PC3

Item {
    id: root
    required property var actionDrawer
    required property int mode
    enum Mode { Pages, ScrollView }
    readonly property real columns: 2
    readonly property real columnWidth: width / columns
    readonly property int minimizedColumns: 4
    readonly property real minimizedColumnWidth: width / minimizedColumns
    readonly property real rowHeight: Kirigami.Units.gridUnit * 4
    readonly property real minimizedRowHeight: Kirigami.Units.gridUnit * 3
    readonly property real intendedColumnWidth: Kirigami.Units.gridUnit * 7
    readonly property real intendedMinimizedColumnWidth: Kirigami.Units.gridUnit * 4
    readonly property int columnCount: 2
    readonly property int rowCount: 2
    readonly property int pageSize: 4
    readonly property int quickSettingsCount: 4
    readonly property real fullHeight: column.implicitHeight
    property real minimizedViewProgress: 0
    property real fullViewProgress: 1
    function resetSwipeView() {}
    ColumnLayout {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Kirigami.Units.smallSpacing
        GridLayout {
            Layout.fillWidth: true
            columns: 2
            columnSpacing: Kirigami.Units.smallSpacing
            rowSpacing: Kirigami.Units.smallSpacing
            PC3.Button {
                Layout.fillWidth: true
                icon.name: ShellUtil.networkReachable()
                    ? (ShellUtil.networkIsCellular() ? "network-mobile-100" : "network-wireless-signal-excellent")
                    : "network-disconnect"
                text: ShellUtil.networkReachable()
                    ? (ShellUtil.networkIsCellular() ? i18n("Cellular") : i18n("Wi-Fi"))
                    : i18n("Offline")
                enabled: false
            }
            PC3.Button {
                Layout.fillWidth: true
                icon.name: BatteryInfo.icon
                text: i18n("%1%", BatteryInfo.percent)
                enabled: false
            }
            PC3.Button {
                Layout.fillWidth: true
                icon.name: AudioInfo.icon
                text: i18n("%1%", AudioInfo.volumeValue)
                onClicked: AudioInfo.muteVolume()
            }
            PC3.Button {
                Layout.fillWidth: true
                icon.name: "preferences-desktop-wallpaper"
                text: i18n("Wallpaper")
                onClicked: root.actionDrawer.wallpaperSettingsRequested()
            }
        }
        BrightnessItem { Layout.fillWidth: true }
        RowLayout {
            Layout.fillWidth: true
            PC3.ToolButton { icon.name: "audio-volume-low"; onClicked: AudioInfo.decreaseVolume() }
            PC3.ProgressBar {
                Layout.fillWidth: true
                from: 0
                to: AudioInfo.maxVolumePercent
                value: AudioInfo.volumeValue
            }
            PC3.ToolButton { icon.name: "audio-volume-high"; onClicked: AudioInfo.increaseVolume() }
        }
    }
}
QML

write_block "$mobileshell/QuickSettingsPanel.qml" <<'QML'
import QtQuick 2.15
import QtQuick.Layouts 1.15
import org.kde.kirigami 2.20 as Kirigami

BaseItem {
    id: root
    required property var actionDrawer
    required property real fullScreenHeight
    readonly property real contentImplicitHeight: column.implicitHeight
    padding: Kirigami.Units.smallSpacing * 2
    contentItem: ColumnLayout {
        id: column
        spacing: Kirigami.Units.smallSpacing
        StatusBar {
            Layout.fillWidth: true
            Layout.preferredHeight: Kirigami.Units.gridUnit * 1.5
            backgroundColor: "transparent"
            showSecondRow: false
            showTime: false
            disableSystemTray: root.actionDrawer.restrictedPermissions
        }
        QuickSettings {
            Layout.fillWidth: true
            Layout.preferredHeight: fullHeight
            actionDrawer: root.actionDrawer
            mode: QuickSettings.ScrollView
            minimizedViewProgress: 0
            fullViewProgress: 1
        }
    }
}
QML

write_block "$mobileshell/WallpaperSelector.qml" <<'QML'
import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.Controls 2.15 as Controls
import org.kde.kirigami 2.20 as Kirigami
import org.kde.plasma.private.mobileshell.wallpaperimageplugin as WallpaperImagePlugin

Controls.Drawer {
    id: root
    dragMargin: 0
    required property bool horizontal
    signal wallpaperSettingsRequested()
    readonly property string defaultWallpaper: "/var/jb/usr/share/backgrounds/xios/xios-default.jpg"
    readonly property string nativeWallpaper: "/var/mobile/Library/Preferences/com.max.iosc-wallpaper.jpg"
    width: horizontal ? Kirigami.Units.gridUnit * 14 : parent.width
    height: horizontal ? parent.height : Kirigami.Units.gridUnit * 10
    background: Rectangle { color: Kirigami.Theme.backgroundColor }
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Kirigami.Units.gridUnit
        spacing: Kirigami.Units.smallSpacing
        Kirigami.Heading { Layout.fillWidth: true; level: 3; text: i18n("Wallpaper") }
        Controls.Button {
            Layout.fillWidth: true
            icon.name: "preferences-desktop-wallpaper"
            text: i18n("Use iPad Wallpaper")
            onClicked: WallpaperImagePlugin.WallpaperPlugin.setHomescreenWallpaper(nativeWallpaper)
        }
        Controls.Button {
            Layout.fillWidth: true
            icon.name: "image-x-generic"
            text: i18n("Use Xios Default")
            onClicked: WallpaperImagePlugin.WallpaperPlugin.setHomescreenWallpaper(defaultWallpaper)
        }
        Controls.Button {
            Layout.fillWidth: true
            icon.name: "configure"
            text: i18n("More")
            onClicked: root.wallpaperSettingsRequested()
        }
    }
}
QML

write_block "$mobileshell/AudioApplet.qml" <<'QML'
import QtQuick 2.15
import QtQuick.Layouts 1.15
import org.kde.kirigami 2.20 as Kirigami
import org.kde.plasma.components 3.0 as PC3

ColumnLayout {
    spacing: Kirigami.Units.smallSpacing
    PC3.Label { Layout.fillWidth: true; text: i18n("iPad speakers") }
    PC3.ProgressBar {
        Layout.fillWidth: true
        from: 0
        to: AudioInfo.maxVolumePercent
        value: AudioInfo.volumeValue
    }
}
QML

write_block "$mobileshell/VolumeOSD.qml" <<'QML'
import QtQuick 2.15
import QtQuick.Layouts 1.15
import org.kde.kirigami 2.20 as Kirigami
import org.kde.plasma.components 3.0 as PC3
import org.kde.plasma.private.nanoshell 2.0 as NanoShell

NanoShell.FullScreenOverlay {
    id: window
    visible: false
    color: "transparent"
    property bool suppressActiveClose: false
    property bool showFullApplet: false
    function showOverlay() {
        showFullApplet = false
        showFullScreen()
        hideTimer.restart()
    }
    Timer { id: hideTimer; interval: 2200; onTriggered: window.close() }
    Rectangle {
        width: Math.min(parent.width - Kirigami.Units.gridUnit * 2, Kirigami.Units.gridUnit * 22)
        height: Kirigami.Units.gridUnit * 5
        radius: Kirigami.Units.smallSpacing
        color: Kirigami.Theme.backgroundColor
        border.color: Kirigami.Theme.disabledTextColor
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: Kirigami.Units.gridUnit
        RowLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.gridUnit
            Kirigami.Icon { Layout.preferredWidth: Kirigami.Units.iconSizes.medium; Layout.preferredHeight: Layout.preferredWidth; source: AudioInfo.icon }
            PC3.ProgressBar { Layout.fillWidth: true; from: 0; to: AudioInfo.maxVolumePercent; value: AudioInfo.volumeValue }
            PC3.Label { text: i18n("%1%", AudioInfo.volumeValue) }
        }
    }
}
QML

write_block "$mobileshell/VolumeOSDProvider.qml" <<'QML'
import QtQuick 2.15

QtObject {
    id: root
    function showVolumeOverlay() { osd.showOverlay() }
    Component.onCompleted: AudioInfo.volumeChanged.connect(showVolumeOverlay)
    property var osd: VolumeOSD {}
}
QML

write_block "$mobileshell/VolumeOSDProviderLoader.qml" <<'QML'
pragma Singleton
import QtQuick 2.15

Loader {
    id: root
    active: false
    sourceComponent: Component { VolumeOSDProvider {} }
    function load() { active = true }
}
QML

write_block "$mobileshell/BatteryInfo.qml" <<'QML'
pragma Singleton
import QtQuick 2.15

QtObject {
    id: root
    readonly property string sysRoot: "/var/jb/sys"
    property bool isVisible: true
    property int percent: 100
    property bool pluggedIn: false
    property string status: "unknown"
    readonly property string icon: iconName()
    function readText(path, fallbackValue) {
        var text = ShellUtil.readTextFile(path)
        return text.length > 0 ? text : fallbackValue
    }
    function readInt(path, fallbackValue) {
        var value = parseInt(readText(path, ""))
        return isNaN(value) ? fallbackValue : value
    }
    function refresh() {
        var present = readInt(sysRoot + "/class/power_supply/BAT0/present", 1)
        status = readText(sysRoot + "/class/power_supply/BAT0/status", "Unknown").toLowerCase()
        isVisible = present !== 0
        percent = Math.max(0, Math.min(100, readInt(sysRoot + "/class/power_supply/BAT0/capacity", percent)))
        pluggedIn = readInt(sysRoot + "/class/power_supply/AC0/online", 0) !== 0 || status.indexOf("charging") !== -1
    }
    function iconName() {
        var bucket = percent < 15 ? "caution" : percent < 35 ? "low" : percent < 75 ? "good" : "full"
        return "battery-" + bucket + (pluggedIn ? "-charging" : "")
    }
    Component.onCompleted: refresh()
    property Timer refreshTimer: Timer { interval: 30000; running: true; repeat: true; onTriggered: root.refresh() }
}
QML

write_block "$mobileshell/SignalStrengthInfo.qml" <<'QML'
pragma Singleton
import QtQuick 2.15

QtObject {
    id: root
    property bool reachable: false
    property bool cellular: false
    readonly property string icon: cellular && reachable ? "network-mobile-100" : "network-mobile-0"
    readonly property string label: cellular ? "Cellular" : ""
    readonly property bool showIndicator: cellular && reachable
    function refresh() {
        reachable = ShellUtil.networkReachable()
        cellular = ShellUtil.networkIsCellular()
    }
    Component.onCompleted: refresh()
    property Timer refreshTimer: Timer { interval: 30000; running: true; repeat: true; onTriggered: root.refresh() }
}
QML

write_block "$mobileshell/AudioInfo.qml" <<'QML'
pragma Singleton
import QtQuick 2.15

QtObject {
    id: root
    readonly property bool isVisible: true
    readonly property string icon: iconName(volumeValue, muted)
    readonly property int maxVolumePercent: 100
    readonly property int maxVolumeValue: 100
    readonly property int volumeStep: 5
    property int volumeValue: 0
    property bool muted: false
    property var paSinkModel: null
    signal volumeChanged()
    function pulse(command) {
        return ShellUtil.runCommand(". /var/jb/etc/profile.d/xios-pulse.sh 2>/dev/null; xios_pulse_start >/dev/null 2>&1; " + command, 1500)
    }
    function refresh() {
        var volume = pulse("pactl get-sink-volume xios 2>/dev/null | sed -n 's/.*\\/ *\\([0-9][0-9]*\\)%.*/\\1/p' | head -1")
        var value = parseInt(volume)
        if (!isNaN(value)) volumeValue = Math.max(0, Math.min(maxVolumePercent, value))
        muted = pulse("pactl get-sink-mute xios 2>/dev/null | awk '{print $2}'") === "yes"
    }
    function increaseVolume() { pulse("pactl set-sink-volume xios +5%"); refresh(); volumeChanged() }
    function decreaseVolume() { pulse("pactl set-sink-volume xios -5%"); refresh(); volumeChanged() }
    function muteVolume() { pulse("pactl set-sink-mute xios toggle"); refresh(); volumeChanged() }
    function setVolumePercent(percent) {
        var bounded = Math.max(0, Math.min(maxVolumePercent, Math.round(percent)))
        pulse("pactl set-sink-volume xios " + bounded + "%")
        refresh()
        volumeChanged()
    }
    function iconName(volume, isMuted, prefix) {
        var base = prefix || "audio-volume"
        if (isMuted || volume <= 0) return base + "-muted"
        if (volume <= 25) return base + "-low"
        if (volume <= 75) return base + "-medium"
        return base + "-high"
    }
    function volumePercent(volume, max) { return Math.round(volume) }
    Component.onCompleted: refresh()
    property Timer refreshTimer: Timer { interval: 10000; running: true; repeat: true; onTriggered: root.refresh() }
}
QML

folio_settings="$qml/../../../share/plasma/plasmoids/org.kde.plasma.mobile.homescreen.folio/contents/ui/settings"
if [ -d "$folio_settings" ]; then
  restore_upstream_file "$folio_settings/AppletListViewer.qml"
fi

folio_ui="$qml/../../../share/plasma/plasmoids/org.kde.plasma.mobile.homescreen.folio/contents/ui"
if [ -d "$folio_ui" ]; then
  restore_upstream_file "$folio_ui/main.qml"
  if [ -e "$folio_ui/delegate/AppDelegate.qml" ]; then
    python3 - "$folio_ui/delegate/AppDelegate.qml" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
if "xios-folio-app-fallback" in text:
    raise SystemExit(0)

needle = """    contentItem: Item {
        height: folio.FolioSettings.delegateIconSize
        width: folio.FolioSettings.delegateIconSize
"""
fallback = """    contentItem: Item {
        height: folio.FolioSettings.delegateIconSize
        width: folio.FolioSettings.delegateIconSize

        // xios-folio-app-fallback: keep homescreen apps visible when Kirigami.Icon is rasterless on iOS.
        Rectangle {
            anchors.fill: parent
            radius: Math.max(8, width * 0.22)
            color: Kirigami.Theme.highlightColor
            opacity: 0.82
            border.color: Qt.rgba(1, 1, 1, 0.22)
            border.width: 1

            Controls.Label {
                anchors.centerIn: parent
                color: Kirigami.Theme.highlightedTextColor
                text: root.application && root.application.name ? root.application.name.substring(0, 1).toUpperCase() : "?"
                font.bold: true
                font.pixelSize: Math.max(18, parent.height * 0.42)
            }
        }
"""
if needle in text:
    path.write_text(text.replace(needle, fallback, 1))
PY
  fi
  if [ -e "$folio_ui/HomeScreenPage.qml" ]; then
    python3 - "$folio_ui/HomeScreenPage.qml" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
if "xios-folio-page-fallback" in text:
    raise SystemExit(0)

needle = """            Loader {
                id: loader
                anchors.top: parent.top
                anchors.left: parent.left
"""
fallback = """            // xios-folio-page-fallback: render a usable app tile when the delegate icon path is transparent on iOS.
            Rectangle {
                id: xiosAppTileFallback
                visible: delegate.pageDelegate.type === Folio.FolioDelegate.Application
                width: Math.min(Math.max(72, folio.FolioSettings.delegateIconSize * 1.3), folio.HomeScreenState.pageCellWidth * 0.62)
                height: width
                radius: Math.max(10, width * 0.24)
                x: (folio.HomeScreenState.pageCellWidth - width) / 2
                y: Math.max(0, (folio.HomeScreenState.pageCellHeight - height) / 2 - Kirigami.Units.gridUnit)
                color: Kirigami.Theme.highlightColor
                opacity: 0.88
                border.color: Qt.rgba(1, 1, 1, 0.22)
                border.width: 1

                PC3.Label {
                    anchors.centerIn: parent
                    color: Kirigami.Theme.highlightedTextColor
                    text: delegate.pageDelegate.application && delegate.pageDelegate.application.name ? delegate.pageDelegate.application.name.substring(0, 1).toUpperCase() : "?"
                    font.bold: true
                    font.pixelSize: Math.max(22, parent.height * 0.44)
                }
            }

            PC3.Label {
                visible: xiosAppTileFallback.visible && folio.FolioSettings.showPagesAppLabels
                x: 0
                y: xiosAppTileFallback.y + xiosAppTileFallback.height + Kirigami.Units.smallSpacing
                width: folio.HomeScreenState.pageCellWidth
                color: Kirigami.Theme.textColor
                text: delegate.pageDelegate.application && delegate.pageDelegate.application.name ? delegate.pageDelegate.application.name : ""
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                maximumLineCount: 1
                font.pixelSize: 14
            }

            Loader {
                id: loader
                anchors.top: parent.top
                anchors.left: parent.left
"""
if needle in text:
    path.write_text(text.replace(needle, fallback, 1))
PY
  fi
  if [ -e "$folio_ui/settings/SettingsWindow.qml" ]; then
    python3 - "$folio_ui/settings/SettingsWindow.qml" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
if "xios-folio-settings-fallback" not in text:
    needle = "    property Folio.HomeScreen folio\n"
    fallback = """    property Folio.HomeScreen folio
    // xios-folio-settings-fallback: settings can bind before the Folio object is attached.
    readonly property var xiosFolioSettings: root.folio && root.folio.FolioSettings ? root.folio.FolioSettings : xiosFallbackFolioSettings
    readonly property var xiosHomeScreenState: root.folio && root.folio.HomeScreenState ? root.folio.HomeScreenState : xiosFallbackHomeScreenState

    QtObject {
        id: xiosFallbackHomeScreenState
        property int pageCellHeight: 128
        property int pageCellWidth: 128
        property int pageOrientation: Folio.HomeScreenState.RegularPosition
    }

    QtObject {
        id: xiosFallbackFolioSettings
        property int delegateIconSize: 64
        property int homeScreenRows: 6
        property int homeScreenColumns: 4
        property bool showPagesAppLabels: true
        property bool showFavouritesAppLabels: true
        property int pageTransitionEffect: Folio.FolioSettings.SlideTransition
        property bool showFavouritesBarBackground: false
        property bool showWallpaperBlur: false
        function saveLayoutToFile(path) { return false }
        function loadLayoutFromFile(path) { return false }
    }
"""
    if needle in text:
        text = text.replace(needle, fallback, 1)
text = text.replace("folio.FolioSettings", "root.xiosFolioSettings")
text = text.replace("folio.HomeScreenState", "root.xiosHomeScreenState")
text = text.replace("root.root.xiosFolioSettings", "root.folio.FolioSettings")
text = text.replace("root.root.xiosHomeScreenState", "root.folio.HomeScreenState")
path.write_text(text)
PY
  fi
fi

halcyon_ui="$qml/../../../share/plasma/plasmoids/org.kde.plasma.mobile.homescreen.halcyon/contents/ui"
if [ -d "$halcyon_ui" ]; then
  restore_upstream_file "$halcyon_ui/main.qml"
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
  restore_upstream_file "$lockscreen/PasswordBar.qml"
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
for cleanup_root in "$qml" "$qml/../../../share/plasma"; do
  [ -d "$cleanup_root" ] || continue
  find "$cleanup_root" -type f -name '*.upstream' -delete
done
