#!/usr/bin/env bash
# plasma-mobile-ios-fixes.sh — first-light trims for Plasma Mobile on iOS.
set -euo pipefail

src=${1:?usage: plasma-mobile-ios-fixes.sh <plasma-mobile-source-dir>}

python3 - "$src/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

text = text.replace("    ModemManagerQt\n    NetworkManagerQt\n", "")
for old, new in [
    ("find_package(KF6Screen CONFIG REQUIRED)", "find_package(KF6Screen CONFIG)"),
    ("find_package(KF6KirigamiAddons 0.6 REQUIRED)", "find_package(KF6KirigamiAddons 0.6)"),
    ("find_package(XCB REQUIRED COMPONENTS XCB)", "find_package(XCB COMPONENTS XCB)"),
    ("find_package(Libudev REQUIRED)", "find_package(Libudev)"),
    ("    TYPE REQUIRED\n    PURPOSE \"Needed for virtual keyboard toggle button\"", "    TYPE OPTIONAL\n    PURPOSE \"Needed for virtual keyboard toggle button\""),
]:
    text = text.replace(old, new)

keep = {"bin", "components", "containments", "quicksettings"}

def subdir_repl(match: re.Match[str]) -> str:
    name = match.group(1)
    if name in keep:
        return match.group(0)
    return f"# ios-firstlight-skip: {match.group(0)}"

text = re.sub(r"^add_subdirectory\(([^)]+)\)", subdir_repl, text, flags=re.M)
text = re.sub(r"^ki18n_install\(po\)", "# ios-firstlight-skip: ki18n_install(po)", text, flags=re.M)
path.write_text(text)
PY

# Keep the QML plugin family needed by the mobile shell/homescreen, while
# skipping the modem and wallpaper service plugins that need later bridge work.
python3 - "$src/components/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
keep = {
    "hapticsplugin",
    "mobileshell",
    "mobileshellstate",
    "quicksettingsplugin",
    "windowplugin",
    "shellsettingsplugin",
}
text = re.sub(
    r"^add_subdirectory\(([^)]+)\)",
    lambda m: m.group(0) if m.group(1) in keep else f"# ios-firstlight-skip: {m.group(0)}",
    text,
    flags=re.M,
)
path.write_text(text)
PY

# Keep mostly data/package installs in this first-light wave. The matching C++
# applet/plugin backends mostly need the next support-library wave or device
# services; the taskpanel applet plugin is small enough to keep.
python3 - "$src/containments/panel/CMakeLists.txt" "$src/containments/taskpanel/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

for arg in sys.argv[1:]:
    path = Path(arg)
    text = path.read_text()
    text = re.sub(r"(?ms)^set\(.*?^install\(TARGETS .*?\n", "# ios-firstlight-skip: C++ containment plugin\n", text)
    path.write_text(text)
PY

python3 - "$src/containments/homescreens/halcyon/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

for arg in sys.argv[1:]:
    path = Path(arg)
    text = path.read_text()
    text = re.sub(r"(?ms)^set\(.*?^install\(TARGETS .*?\n", "# ios-firstlight-skip: C++ homescreen plugin\n", text)
    text = re.sub(r"^add_subdirectory\(plugin\)", "# ios-firstlight-skip: add_subdirectory(plugin)", text, flags=re.M)
    path.write_text(text)
PY

# Folio registers its private QML types from the containment plugin constructor.
# Install a module directory so `import org.kde.private.mobile.homescreen.folio`
# resolves once the containment has registered those types.
python3 - "$src/containments/homescreens/folio/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
needle = "plasma_install_package(package org.kde.plasma.mobile.homescreen.folio)\n"
install = """plasma_install_package(package org.kde.plasma.mobile.homescreen.folio)

file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/qmldir" "module org.kde.private.mobile.homescreen.folio\\n")
install(FILES "${CMAKE_CURRENT_BINARY_DIR}/qmldir" DESTINATION ${KDE_INSTALL_QMLDIR}/org/kde/private/mobile/homescreen/folio)
"""
if needle in text and "org/kde/private/mobile/homescreen/folio" not in text:
    text = text.replace(needle, install)
path.write_text(text)
PY

for dir in flashlight nightcolor powermenu screenshot screenrotation; do
  cmake="$src/quicksettings/$dir/CMakeLists.txt"
  [ -f "$cmake" ] || continue
  python3 - "$cmake" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(r"(?ms)^.*?plasma_install_package\(", "plasma_install_package(", text, count=1)
path.write_text(text)
PY
done

# Give the first-light QML providers a tiny shared bridge to existing Xios
# services instead of inventing KDE-specific daemons. Battery/brightness use
# xios-fhs files; audio uses the PulseAudio session helpers.
python3 - "$src/components/mobileshell/shellutil.h" "$src/components/mobileshell/shellutil.cpp" <<'PY'
import sys
from pathlib import Path

header = Path(sys.argv[1])
source = Path(sys.argv[2])

h = header.read_text()
if "readTextFile(const QString &path)" not in h:
    h = h.replace(
        "    Q_INVOKABLE void executeCommand(const QString &command);\n",
        """    Q_INVOKABLE void executeCommand(const QString &command);

    /**
     * Read a small text file for iOS service-backed QML providers.
     */
    Q_INVOKABLE QString readTextFile(const QString &path);

    /**
     * Write a small text file for iOS service-backed QML providers.
     */
    Q_INVOKABLE bool writeTextFile(const QString &path, const QString &contents);

    /**
     * Run a bounded shell command and return stdout. Intended for low-frequency
     * status probes such as pactl; never call this from animation paths.
     */
    Q_INVOKABLE QString runCommand(const QString &command, int timeoutMs = 1500);
""",
    )
    header.write_text(h)

c = source.read_text()
if "ShellUtil::readTextFile" not in c:
    c = c.replace(
        "#include <QProcess>\n",
        "#include <QProcess>\n#include <QTextStream>\n",
    )
    marker = """void ShellUtil::executeCommand(const QString &command)
{
    qWarning() << "Executing" << command;
    const QStringList commandAndArguments = QProcess::splitCommand(command);
    QProcess::startDetached(commandAndArguments.front(), commandAndArguments.mid(1));
}
"""
    impl = marker + r'''
QString ShellUtil::readTextFile(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text)) {
        return QString();
    }
    return QString::fromUtf8(file.readAll()).trimmed();
}

bool ShellUtil::writeTextFile(const QString &path, const QString &contents)
{
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
        qWarning() << "Could not write" << path << file.errorString();
        return false;
    }
    QTextStream stream(&file);
    stream << contents;
    if (!contents.endsWith(QLatin1Char('\n'))) {
        stream << Qt::endl;
    }
    return file.error() == QFile::NoError;
}

QString ShellUtil::runCommand(const QString &command, int timeoutMs)
{
    QProcess process;
    process.start(QStringLiteral("/var/jb/bin/sh"), {QStringLiteral("-lc"), command});
    if (!process.waitForStarted(timeoutMs)) {
        qWarning() << "Could not start command" << command;
        return QString();
    }
    if (!process.waitForFinished(timeoutMs)) {
        qWarning() << "Command timed out" << command;
        process.kill();
        process.waitForFinished(250);
        return QString();
    }
    return QString::fromUtf8(process.readAllStandardOutput()).trimmed();
}
'''
    if marker not in c:
        raise SystemExit("shellutil.cpp marker not found")
    c = c.replace(marker, impl, 1)
    source.write_text(c)
PY

# Several MobileShell QML files are embedded into the private plugin resource
# system, so package-time QML replacements do not affect the qrc:/ load path.
# Keep the plugin importable for first light, but replace Flickable-derived
# startup views and heavy widgets before CMake snapshots them into resources.
python3 - "$src" <<'PY'
import sys
from pathlib import Path

src = Path(sys.argv[1])

def write(rel: str, text: str) -> None:
    path = src / rel
    if not path.exists():
        return
    backup = path.with_suffix(path.suffix + ".upstream")
    if not backup.exists():
        backup.write_text(path.read_text())
    path.write_text(text.strip() + "\n")

view_common = """import QtQuick 2.15
Item {
    id: root
    property var model: null
    property Component delegate: null
    property Component highlight: null
    property int count: 0
    property int currentIndex: -1
    property int cellWidth: width
    property int cellHeight: 96
    property int flow: 0
    property int orientation: 0
    property int layoutDirection: Qt.LeftToRight
    property int verticalLayoutDirection: 0
    property int boundsBehavior: 0
    property int boundsMovement: 0
    property int flickableDirection: 0
    property int highlightRangeMode: 0
    property int headerPositioning: 0
    property int snapMode: 0
    property bool interactive: false
    property bool dragging: false
    property bool moving: false
    property bool reuseItems: false
    property bool keyNavigationWraps: false
    property bool keyNavigationEnabled: true
    property bool atYBeginning: true
    property bool atYEnd: true
    property real cacheBuffer: 0
    property real flickDeceleration: 0
    property real pressDelay: 0
    property real contentX: 0
    property real contentY: 0
    property real contentWidth: width
    property real contentHeight: height
    property real topMargin: 0
    property real bottomMargin: 0
    property real leftMargin: 0
    property real rightMargin: 0
    property real displayMarginBeginning: 0
    property real displayMarginEnd: 0
    property real preferredHighlightBegin: 0
    property real preferredHighlightEnd: 0
    property real highlightMoveDuration: 0
    property real highlightResizeDuration: 0
    property real maximumFlickVelocity: 0
    property real spacing: 0
    readonly property Item currentItem: null
    property var add: null
    property var displaced: null
    property var header: null
    property bool highlightFollowsCurrentItem: true
    default property alias content: contentItem.data
    Item { id: contentItem; anchors.fill: parent }
    signal movementStarted()
    signal movementEnded()
    signal flickStarted()
    signal flickEnded()
    function itemAtIndex(index) { return null }
    function indexAt(x, y) { return -1 }
    function flick(xVelocity, yVelocity) {}
    function positionViewAtIndex(index, mode) {}
    function resizeContent(width, height, center) { contentWidth = width; contentHeight = height }
    function returnToBounds() {}
}
"""

write("components/mobileshell/qml/components/GridView.qml", view_common)
write("components/mobileshell/qml/components/ListView.qml", view_common)
write("components/mobileshell/qml/components/Flickable.qml", view_common)

item_stub = """import QtQuick 2.15
Item {
    id: root
    enum Mode { Pages, Grid, List }
    property var shell
    property var state
    property var window
    property var screen
    property var panel
    property var containment
    property var plasmoid
    property var model
    property var sourceModel
    property var currentPlayer
    property var popup
    property var homeScreen
    property var folio
    property var actionDrawer
    property var notificationModel
    property var notificationSettings
    property var notificationsWidget: ({
        doNotDisturbModeEnabled: false,
        toggleDoNotDisturbMode: function() { this.doNotDisturbModeEnabled = !this.doNotDisturbModeEnabled }
    })
    property var restrictedPermissions
    property var historyModel
    property var pendingNotificationWithAction
    property var textField
    property var view
    property var statusNotifierSource
    property Component content
    default property alias contentChildren: contentItem.data
    property int edge: Qt.BottomEdge
    property int notificationModelType: 0
    property int historyModelType: 0
    property int columns: 1
    property int columnCount: columns
    property int minimizedColumns: 1
    property int quickSettingsCount: 0
    property int rowCount: 0
    property int pageSize: 0
    property int previewCharIndex: -1
    property int animationDuration: 0
    property int direction: Qt.BottomEdge
    property string queryString: ""
    property string backgroundColor: "transparent"
    property string pluginName: ""
    property string pinLabel: ""
    property string prevText: ""
    property color colorScopeColor: "transparent"
    property color color: "transparent"
    property color headerTextColor: "transparent"
    property color headerTextInactiveColor: "transparent"
    property bool active: false
    property bool expanded: false
    property bool shown: false
    property bool dragging: false
    property bool opened: shown
    property bool opening: false
    property bool isOpen: shown
    property bool horizontal: false
    property bool showSecondRow: false
    property bool showDropShadow: false
    property bool disableSystemTray: false
    property bool actionsRequireUnlock: false
    property bool openToPinnedMode: false
    property bool doNotDisturbModeEnabled: false
    property bool hasNotifications: false
    property bool listOverflowing: false
    property bool externalEdit: false
    property bool isPinMode: false
    property bool keypadOpen: false
    property bool showChar: false
    property bool showFullApplet: false
    property bool suppressActiveClose: false
    property bool isCurrent: false
    property bool isOnLargeScreen: false
    property bool showTime: true
    property real availableHeight: height
    property real topMargin: 0
    property real bottomMargin: 0
    property real leftMargin: 0
    property real rightMargin: 0
    property real offset: 0
    property real oldOffset: 0
    property real oldMouseY: 0
    property real offsetDist: 0
    property real offsetHeight: 0
    property real totalOffsetDist: 0
    property real largePortraitThreshold: 0
    property real maximizedQuickSettingsOffset: 0
    property real minimizedQuickSettingsOffset: 0
    property real minimizedViewProgress: 0
    property real fullViewProgress: 0
    property real closedContentY: 0
    property real oldContentY: 0
    property real openFactor: 0
    property real openedContentY: 0
    property real contentHeight: height
    property real padding: 0
    property real horizontalMargin: 0
    property real intendedCellWidth: 0
    property real maxCellWidth: 0
    property real zoomScale: 1
    property real columnWidth: 0
    property real fullHeight: height
    property real intendedColumnWidth: 0
    property real intendedMinimizedColumnWidth: 0
    property real minimizedColumnWidth: 0
    property real minimizedRowHeight: 0
    property real rowHeight: 0
    property real dotWidth: 0
    property real intendedWidth: width
    property real minWidthHeight: Math.min(width, height)
    property real offsetRatio: 0
    property real opacityValue: opacity
    property real contentImplicitHeight: implicitHeight
    property real elementSpacing: 0
    property real smallerTextPixelSize: 12
    property real textPixelSize: 14
    property var lockScreenState
    property int mode: 0
    Item { id: contentItem; anchors.fill: parent }
    signal closed()
    signal requestedClose()
    signal requestClose()
    signal drawerClosed()
    signal drawerOpened()
    signal permissionsRequested()
    signal runPendingNotificationAction()
    signal actionTriggered()
    signal activated()
    signal backgroundClicked()
    signal unlockRequested()
    signal wallpaperSettingsRequested()
    function open() { shown = true }
    function close() { shown = false; closed(); requestedClose(); requestClose() }
    function closeImmediately() { close() }
    function toggle() { shown = !shown; if (!shown) { backgroundClicked() } }
    function expand() { expanded = true }
    function cancelAnimations() {}
    function updateState() {}
    function startSwipe() {}
    function updateOffset(value) { offset = value }
    function endSwipe() {}
    function activateNextAction() {}
    function clearField() {}
    function requestFocus() { forceActiveFocus() }
    function startGesture() {}
    function updateGestureOffset(value) { offset = value }
    function endGesture() {}
    function getTrackName() { return "" }
    function clearHistory() {}
    function isRowExpanded(row) { return false }
    function openNotificationSettings() {}
    function runPendingAction() {}
    function setGroupExpanded(group, expanded) {}
    function toggleDoNotDisturbMode() { doNotDisturbModeEnabled = !doNotDisturbModeEnabled }
    function applyMinMax(value) { return value }
    function onRunPendingNotificationAction() {}
    function onOpenedChanged() {}
    function resetSwipeView() {}
    function showOverlay() { shown = true }
    function backspace() {}
    function clear() {}
    function enter() {}
    function keyPress(key, text, modifiers) {}
    function onPasswordChanged() {}
    function onUnlockFailed() {}
    function onUnlockSucceeded() {}
}
"""

for rel in [
    "components/mobileshell/qml/ActionDrawer.qml",
    "components/mobileshell/qml/ActionDrawerOpenSurface.qml",
    "components/mobileshell/qml/PortraitContentContainer.qml",
    "components/mobileshell/qml/actiondrawer/LandscapeContentContainer.qml",
    "components/mobileshell/qml/actiondrawer/quicksettings/QuickSettings.qml",
    "components/mobileshell/qml/actiondrawer/quicksettings/QuickSettingsPanel.qml",
    "components/mobileshell/qml/statusbar/StatusBar.qml",
    "components/mobileshell/qml/homescreen/WallpaperSelector.qml",
    "components/mobileshell/qml/volumeosd/AudioApplet.qml",
    "components/mobileshell/qml/volumeosd/VolumeOSD.qml",
    "components/mobileshell/qml/widgets/krunner/KRunnerScreen.qml",
    "components/mobileshell/qml/widgets/krunner/KRunnerWidget.qml",
    "components/mobileshell/qml/widgets/mediacontrols/MediaControlsWidget.qml",
    "components/mobileshell/qml/widgets/notifications/NotificationsWidget.qml",
]:
    write(rel, item_stub)

write("components/mobileshell/qml/volumeosd/VolumeOSDProvider.qml", """import QtQuick 2.15
QtObject {
    id: root
    function showVolumeOverlay() {}
}
""")

write("components/mobileshell/qml/volumeosd/VolumeOSDProviderLoader.qml", """pragma Singleton
import QtQuick 2.15
QtObject {
    id: root
    property bool active: false
    function load() { active = true }
}
""")

write("components/mobileshell/qml/statusbar/ClockText.qml", """import QtQuick 2.15
import QtQuick.Controls 2.15
Label {
    id: root
    property var source
    property bool is24HourTime: true
    text: Qt.formatTime(new Date(), is24HourTime ? "h:mm" : "h:mm ap")
    verticalAlignment: Text.AlignVCenter
    Timer {
        interval: 60000
        running: true
        repeat: true
        onTriggered: root.text = Qt.formatTime(new Date(), root.is24HourTime ? "h:mm" : "h:mm ap")
    }
}
""")

write("components/mobileshell/qml/dataproviders/BatteryInfo.qml", """pragma Singleton
import QtQuick 2.15
QtObject {
    id: root
    readonly property string sysRoot: "/var/jb/sys"
    property bool isVisible: true
    property int percent: 100
    property bool pluggedIn: false
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
        var status = readText(sysRoot + "/class/power_supply/BAT0/status", "Unknown").toLowerCase()
        isVisible = present !== 0
        percent = Math.max(0, Math.min(100, readInt(sysRoot + "/class/power_supply/BAT0/capacity", percent)))
        pluggedIn = readInt(sysRoot + "/class/power_supply/AC0/online", 0) !== 0 || status.indexOf("charging") !== -1
    }
    Component.onCompleted: refresh()
    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }
}
""")

write("components/mobileshell/qml/dataproviders/AudioInfo.qml", """pragma Singleton
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
        var volume = pulse("pactl get-sink-volume xios 2>/dev/null | sed -n 's/.*\\\\/ *\\\\([0-9][0-9]*\\\\)%.*/\\\\1/p' | head -1")
        var value = parseInt(volume)
        if (!isNaN(value)) {
            volumeValue = Math.max(0, Math.min(maxVolumePercent, value))
        }
        muted = pulse("pactl get-sink-mute xios 2>/dev/null | awk '{print $2}'") === "yes"
    }
    function increaseVolume() {
        pulse("pactl set-sink-volume xios +5%")
        refresh()
        volumeChanged()
    }
    function decreaseVolume() {
        pulse("pactl set-sink-volume xios -5%")
        refresh()
        volumeChanged()
    }
    function muteVolume() {
        pulse("pactl set-sink-mute xios toggle")
        refresh()
        volumeChanged()
    }
    function iconName(volume, isMuted, prefix) {
        var base = prefix || "audio-volume"
        if (isMuted || volume <= 0) {
            return base + "-muted"
        } else if (volume <= 25) {
            return base + "-low"
        } else if (volume <= 75) {
            return base + "-medium"
        }
        return base + "-high"
    }
    function volumePercent(volume, max) { return Math.round(volume) }
    Component.onCompleted: refresh()
    Timer {
        interval: 10000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }
}
""")

panel = src / "shell/contents/views/Panel.qml"
if panel.exists():
    text = panel.read_text()
    needle = "    Connections {\n        target: containment\n        function onActivated() {"
    if needle in text and "ignoreUnknownSignals: true" not in text:
        text = text.replace(
            needle,
            "    Connections {\n        target: containment\n        ignoreUnknownSignals: true\n        function onActivated() {",
            1,
        )
        panel.write_text(text)

write("containments/homescreens/folio/package/contents/ui/settings/AppletListViewer.qml", """import QtQuick 2.15
MouseArea {
    id: root
    property var folio
    property var homeScreen
    property int columns: 1
    property real horizontalMargin: 0
    property real intendedCellWidth: 0
    property real maxCellWidth: 0
    property real zoomScale: 1
    property string pluginName: ""
    signal requestClose()
    onClicked: root.requestClose()
}
""")

write("containments/homescreens/folio/package/contents/ui/main.qml", """import QtQuick 2.15
import org.kde.plasma.plasmoid 2.0
ContainmentItem {
    id: root
    Item { anchors.fill: parent }
}
""")

write("containments/homescreens/halcyon/package/contents/ui/main.qml", """import QtQuick 2.15
import org.kde.plasma.plasmoid 2.0
ContainmentItem {
    id: root
    Item { anchors.fill: parent }
}
""")

write("shell/package/contents/lockscreen/PasswordBar.qml", """import QtQuick 2.15
import QtQuick.Controls 2.15
Item {
    id: root
    property string password: ""
    property string placeholderText: ""
    property bool keypadOpen: false
    property bool showChar: false
    property bool isPinMode: false
    property bool externalEdit: false
    property int previewCharIndex: -1
    property real dotWidth: 0
    property color color: "transparent"
    property color headerTextColor: "transparent"
    property color headerTextInactiveColor: "transparent"
    property var lockScreenState
    property var textField
    property string pinLabel: ""
    property string prevText: ""
    signal accepted(string password)
    function backspace() {}
    function clear() { password = "" }
    function enter() { accepted(password) }
    function keyPress(key, text, modifiers) {}
    function onPasswordChanged() {}
    function onUnlockFailed() {}
    function onUnlockSucceeded() {}
    TextField {
        anchors.centerIn: parent
        width: Math.min(parent.width, 420)
        placeholderText: root.placeholderText
        echoMode: TextInput.Password
        onAccepted: root.accepted(text)
    }
}
""")
PY

# The real org.kde.plasma.mm plugin depends on NetworkManagerQt and
# ModemManagerQt. iPads do not expose that Linux modem stack, but the upstream
# mobile shell imports the module unconditionally from its status bar and
# taskpanel. Install a tiny no-cellular singleton so those QML files can load
# while the real service bridge remains a later package wave.
python3 - "$src/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
block = r'''

set(IOS_PLASMA_MM_STUB_DIR "${CMAKE_CURRENT_BINARY_DIR}/ios-plasma-mm-stub")
file(MAKE_DIRECTORY "${IOS_PLASMA_MM_STUB_DIR}")
file(WRITE "${IOS_PLASMA_MM_STUB_DIR}/qmldir" "module org.kde.plasma.mm\nsingleton SignalIndicator 1.0 SignalIndicator.qml\n")
file(WRITE "${IOS_PLASMA_MM_STUB_DIR}/SignalIndicator.qml" "pragma Singleton\nimport QtQuick 2.15\nQtObject {\n    property int strength: 0\n    property string name: \"\"\n    property bool modemAvailable: false\n    property bool simLocked: false\n    property bool simEmpty: true\n    property bool mobileDataSupported: false\n    property bool mobileDataEnabled: false\n    property bool needsAPNAdded: false\n    property var profiles: []\n    property string activeConnectionUni: \"\"\n    function refreshProfiles() {}\n    function activateProfile(connectionUni) {}\n    function addProfile(name, apn, username, password, networkType) {}\n    function removeProfile(connectionUni) {}\n    function updateProfile(connectionUni, name, apn, username, password, networkType) {}\n}\n")
install(DIRECTORY "${IOS_PLASMA_MM_STUB_DIR}/" DESTINATION ${KDE_INSTALL_QMLDIR}/org/kde/plasma/mm)
'''
if "IOS_PLASMA_MM_STUB_DIR" not in text:
    text += block
path.write_text(text)
PY
