#!/usr/bin/env bash
# plasma-mobile-ios-fixes.sh — Xios/iOS fixes for Plasma Mobile.
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
    return f"# xios-ios-skip: {match.group(0)}"

text = re.sub(r"^add_subdirectory\(([^)]+)\)", subdir_repl, text, flags=re.M)
text = re.sub(r"^ki18n_install\(po\)", "# xios-ios-skip: ki18n_install(po)", text, flags=re.M)
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

# Keep mostly data/package installs for panel/taskpanel pieces whose matching
# C++ containment plugins still depend on unsupported Linux service paths.
python3 - "$src/containments/panel/CMakeLists.txt" "$src/containments/taskpanel/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

for arg in sys.argv[1:]:
    path = Path(arg)
    text = path.read_text()
    text = re.sub(r"(?ms)^set\(.*?^install\(TARGETS .*?\n", "# xios-ios-skip: C++ containment plugin\n", text)
    path.write_text(text)
PY

python3 - "$src/containments/homescreens/halcyon/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

for arg in sys.argv[1:]:
    path = Path(arg)
    text = path.read_text()
    text = re.sub(r"(?ms)^set\(.*?^install\(TARGETS .*?\n", "# xios-ios-skip: C++ homescreen plugin\n", text)
    text = re.sub(r"^add_subdirectory\(plugin\)", "# xios-ios-skip: add_subdirectory(plugin)", text, flags=re.M)
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

# Folio's app drawer must still populate on iOS even if the KWayland window
# tracking connection is not ready during model construction. The connection is
# only needed for launch/activate state; KApplicationTrader can already list the
# installed apps.
python3 - "$src/containments/homescreens/folio/applicationlistmodel.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
old = """    // initialize wayland window checking
    KWayland::Client::ConnectionThread *connection = KWayland::Client::ConnectionThread::fromApplication(this);
    if (!connection) {
        return;
    }

    load();
"""
new = """    // initialize wayland window checking when available; app listing itself
    // must not depend on this being ready during iOS startup.
    KWayland::Client::ConnectionThread *connection = KWayland::Client::ConnectionThread::fromApplication(this);
    if (!connection) {
        qWarning() << \"xios: Folio ApplicationListModel loading without Wayland connection\";
    }

    load();
"""
if old in text:
    text = text.replace(old, new, 1)
text = text.replace(
    """ApplicationListModel::ApplicationListModel(HomeScreen *parent)
    : QAbstractListModel(parent)
{""",
    """ApplicationListModel::ApplicationListModel(HomeScreen *parent)
    : QAbstractListModel(parent)
    , m_homeScreen{parent}
{""",
    1,
)
text = text.replace(
    """    const KService::List apps = KApplicationTrader::query(filter);

    for (const KService::Ptr &service : apps) {""",
    """    KService::List apps = KApplicationTrader::query(filter);
    if (apps.isEmpty()) {
        const QStringList fallbackIds = {
            QStringLiteral("org.kde.kwrite.desktop"),
            QStringLiteral("org.kde.gwenview.desktop"),
            QStringLiteral("org.kde.ark.desktop"),
            QStringLiteral("systemsettings.desktop"),
        };
        for (const QString &storageId : fallbackIds) {
            KService::Ptr service = KService::serviceByStorageId(storageId);
            if (service && filter(service)) {
                apps << service;
            }
        }
        qWarning() << "xios: Folio ApplicationListModel used storage-id fallback" << apps.size();
    }

    for (const KService::Ptr &service : apps) {""",
    1,
)
path.write_text(text)
PY

# Match the desktop wallpaper default for fresh Mobile configs.
# Without the concrete org.kde.image config group, the wallpaper backend starts
# from its preferred:// default and reports Provider.Unknown on iOS.
python3 - "$src/shell/contents/layout.js" <<'PY'
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

# Give the QML providers a tiny shared bridge to existing Xios services instead
# of inventing KDE-specific daemons. Battery/brightness use xios-fhs files;
# audio uses the PulseAudio session helpers.
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

if "networkReachable()" not in h:
    h = h.replace(
        "    Q_INVOKABLE QString runCommand(const QString &command, int timeoutMs = 1500);\n",
        """    Q_INVOKABLE QString runCommand(const QString &command, int timeoutMs = 1500);

    /**
     * Return iOS reachability for the default route.
     */
    Q_INVOKABLE bool networkReachable();

    /**
     * Return whether the current reachable default route is cellular.
     */
    Q_INVOKABLE bool networkIsCellular();
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

if "ShellUtil::networkReachable" not in c:
    c = c.replace(
        "#include <QTextStream>\n",
        """#include <QTextStream>

#if defined(Q_OS_DARWIN)
#include <SystemConfiguration/SystemConfiguration.h>
#include <netinet/in.h>
#include <sys/socket.h>
#endif
""",
    )
    network_impl = r'''
#if defined(Q_OS_DARWIN)
static bool xiosNetworkReachabilityFlags(SCNetworkReachabilityFlags *flags)
{
    sockaddr_in address = {};
    address.sin_len = sizeof(address);
    address.sin_family = AF_INET;
    SCNetworkReachabilityRef reachability =
        SCNetworkReachabilityCreateWithAddress(nullptr, reinterpret_cast<const sockaddr *>(&address));
    if (!reachability) {
        return false;
    }
    const bool ok = SCNetworkReachabilityGetFlags(reachability, flags);
    CFRelease(reachability);
    return ok;
}
#endif

bool ShellUtil::networkReachable()
{
#if defined(Q_OS_DARWIN)
    SCNetworkReachabilityFlags flags = 0;
    if (!xiosNetworkReachabilityFlags(&flags)) {
        return false;
    }
    const bool reachable = flags & kSCNetworkReachabilityFlagsReachable;
    const bool needsConnection = flags & kSCNetworkReachabilityFlagsConnectionRequired;
    return reachable && !needsConnection;
#else
    return QFile::exists(QStringLiteral("/var/jb/tmp/pulse/native"));
#endif
}

bool ShellUtil::networkIsCellular()
{
#if defined(Q_OS_DARWIN) && defined(kSCNetworkReachabilityFlagsIsWWAN)
    SCNetworkReachabilityFlags flags = 0;
    return xiosNetworkReachabilityFlags(&flags) && (flags & kSCNetworkReachabilityFlagsIsWWAN);
#else
    return false;
#endif
}

'''
    needle = "\nbool ShellUtil::isSystem24HourFormat()\n"
    if needle not in c:
        raise SystemExit("shellutil.cpp isSystem24HourFormat marker not found")
    c = c.replace(needle, "\n" + network_impl + "bool ShellUtil::isSystem24HourFormat()\n", 1)
    source.write_text(c)
PY

python3 - "$src/components/mobileshell/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
if "SystemConfiguration" not in text:
    text += '''

if(APPLE)
    target_link_libraries(mobileshellplugin PRIVATE "-framework SystemConfiguration" "-framework CoreFoundation")
endif()
'''
elif "CoreFoundation" not in text:
    text = text.replace(
        'target_link_libraries(mobileshellplugin PRIVATE "-framework SystemConfiguration")',
        'target_link_libraries(mobileshellplugin PRIVATE "-framework SystemConfiguration" "-framework CoreFoundation")',
    )
path.write_text(text)
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

def restore_upstream(rel: str) -> None:
    path = src / rel
    backup = path.with_suffix(path.suffix + ".upstream")
    if backup.exists():
        path.write_text(backup.read_text())

def patch_folio_app_delegate() -> None:
    path = src / "containments/homescreens/folio/package/contents/ui/delegate/AppDelegate.qml"
    if not path.exists():
        return
    text = path.read_text()
    if "xios-folio-app-fallback" in text:
        return
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

def patch_folio_home_screen_page() -> None:
    path = src / "containments/homescreens/folio/package/contents/ui/HomeScreenPage.qml"
    if not path.exists():
        return
    text = path.read_text()
    if "xios-folio-page-fallback" in text:
        return
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

def patch_folio_settings_window() -> None:
    path = src / "containments/homescreens/folio/package/contents/ui/settings/SettingsWindow.qml"
    if not path.exists():
        return
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
        if needle not in text:
            return
        text = text.replace(needle, fallback, 1)
    text = text.replace("folio.FolioSettings", "root.xiosFolioSettings")
    text = text.replace("folio.HomeScreenState", "root.xiosHomeScreenState")
    text = text.replace("root.root.xiosFolioSettings", "root.folio.FolioSettings")
    text = text.replace("root.root.xiosHomeScreenState", "root.folio.HomeScreenState")
    path.write_text(text)

def patch_folio_app_drawer() -> None:
    path = src / "containments/homescreens/folio/package/contents/ui/AppDrawer.qml"
    if not path.exists():
        return
    text = path.read_text()
    old = """            opacity: 0
            headerHeight: root.headerHeight
"""
    new = """            // xios-folio-drawer-grid-visible: the parent drawer already gates opacity.
            opacity: 1
            headerHeight: root.headerHeight
"""
    if old in text and "xios-folio-drawer-grid-visible" not in text:
        path.write_text(text.replace(old, new, 1))

grid_view_qml = """import QtQuick 2.15 as QtQuick

QtQuick.GridView {
    id: root
    // xios-mobile-real-gridview: real drawer delegates, with iOS edge-hook placeholders.
    property var topEdgeCallback: null
    property var bottomEdgeCallback: null
    property var leftEdgeCallback: null
    property var rightEdgeCallback: null
}
"""

list_view_qml = """import QtQuick 2.15 as QtQuick

QtQuick.ListView {
    id: root
    // xios-mobile-real-listview: the Qt Quick iOS Flickable root fix is in qtdeclarative.
    flickDeceleration: 1500
    maximumFlickVelocity: 5000
    property int currentIndex: -1
    onActiveFocusChanged: if (!activeFocus) currentIndex = -1
    onDraggingChanged: if (dragging) currentIndex = -1
}
"""

flickable_qml = """import QtQuick 2.15 as QtQuick

QtQuick.Flickable {
    id: root
    // xios-mobile-real-flickable: keep upstream behavior with deterministic iOS physics.
    flickDeceleration: 1500
    maximumFlickVelocity: 5000
}
"""

write("components/mobileshell/qml/components/GridView.qml", grid_view_qml)
write("components/mobileshell/qml/components/ListView.qml", list_view_qml)
write("components/mobileshell/qml/components/Flickable.qml", flickable_qml)

write("components/mobileshell/qml/statusbar/StatusBar.qml", """import QtQuick 2.15
import QtQuick.Layouts 1.15
import QtQuick.Controls 2.15 as Controls
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

    function batteryIcon() {
        var pct = BatteryInfo.percent
        var bucket = pct < 15 ? "caution" : pct < 35 ? "low" : pct < 75 ? "good" : "full"
        return "battery-" + bucket + (BatteryInfo.pluggedIn ? "-charging" : "")
    }

    Timer {
        interval: 1000
        running: true
        repeat: true
        onTriggered: root.now = new Date()
    }

    Rectangle {
        anchors.fill: parent
        color: root.backgroundColor
    }

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
                verticalAlignment: Text.AlignVCenter
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
                    source: root.batteryIcon()
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
""")

write("components/mobileshell/qml/actiondrawer/quicksettings/QuickSettings.qml", """import QtQuick 2.15
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
                icon.name: "battery-full" + (BatteryInfo.pluggedIn ? "-charging" : "")
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

        BrightnessItem {
            Layout.fillWidth: true
        }

        RowLayout {
            Layout.fillWidth: true
            PC3.ToolButton {
                icon.name: "audio-volume-low"
                onClicked: AudioInfo.decreaseVolume()
            }
            PC3.ProgressBar {
                Layout.fillWidth: true
                from: 0
                to: AudioInfo.maxVolumePercent
                value: AudioInfo.volumeValue
            }
            PC3.ToolButton {
                icon.name: "audio-volume-high"
                onClicked: AudioInfo.increaseVolume()
            }
        }
    }
}
""")

write("components/mobileshell/qml/actiondrawer/quicksettings/QuickSettingsPanel.qml", """import QtQuick 2.15
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
""")

write("components/mobileshell/qml/homescreen/WallpaperSelector.qml", """import QtQuick 2.15
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

        Kirigami.Heading {
            Layout.fillWidth: true
            level: 3
            text: i18n("Wallpaper")
        }

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
""")

write("components/mobileshell/qml/volumeosd/AudioApplet.qml", """import QtQuick 2.15
import QtQuick.Layouts 1.15
import org.kde.kirigami 2.20 as Kirigami
import org.kde.plasma.components 3.0 as PC3

ColumnLayout {
    spacing: Kirigami.Units.smallSpacing
    PC3.Label {
        Layout.fillWidth: true
        text: i18n("iPad speakers")
    }
    PC3.ProgressBar {
        Layout.fillWidth: true
        from: 0
        to: AudioInfo.maxVolumePercent
        value: AudioInfo.volumeValue
    }
}
""")

write("components/mobileshell/qml/volumeosd/VolumeOSD.qml", """import QtQuick 2.15
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

    Timer {
        id: hideTimer
        interval: 2200
        onTriggered: window.close()
    }

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
            Kirigami.Icon {
                Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                Layout.preferredHeight: Layout.preferredWidth
                source: AudioInfo.icon
            }
            PC3.ProgressBar {
                Layout.fillWidth: true
                from: 0
                to: AudioInfo.maxVolumePercent
                value: AudioInfo.volumeValue
            }
            PC3.Label {
                text: i18n("%1%", AudioInfo.volumeValue)
            }
        }
    }
}
""")

write("components/mobileshell/qml/volumeosd/VolumeOSDProvider.qml", """import QtQuick 2.15

QtObject {
    id: root
    function showVolumeOverlay() { osd.showOverlay() }
    Component.onCompleted: AudioInfo.volumeChanged.connect(showVolumeOverlay)
    property var osd: VolumeOSD {}
}
""")

write("components/mobileshell/qml/volumeosd/VolumeOSDProviderLoader.qml", """pragma Singleton
import QtQuick 2.15
Loader {
    id: root
    active: false
    sourceComponent: Component { VolumeOSDProvider {} }
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
    property Timer refreshTimer: Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: root.refresh()
    }
}
""")

write("components/mobileshell/qml/dataproviders/SignalStrengthInfo.qml", """pragma Singleton
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
    property Timer refreshTimer: Timer {
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
    function setVolumePercent(percent) {
        var bounded = Math.max(0, Math.min(maxVolumePercent, Math.round(percent)))
        pulse("pactl set-sink-volume xios " + bounded + "%")
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
    property Timer refreshTimer: Timer {
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

restore_upstream("containments/homescreens/folio/package/contents/ui/settings/AppletListViewer.qml")
restore_upstream("containments/homescreens/folio/package/contents/ui/main.qml")
restore_upstream("containments/homescreens/halcyon/package/contents/ui/main.qml")
patch_folio_app_delegate()
patch_folio_home_screen_page()
patch_folio_settings_window()
patch_folio_app_drawer()

restore_upstream("shell/package/contents/lockscreen/PasswordBar.qml")

for backup in src.rglob("*.qml.upstream"):
    backup.unlink()
PY

# The real org.kde.plasma.mm plugin depends on NetworkManagerQt and
# ModemManagerQt. iPads do not expose that Linux modem stack, but the upstream
# mobile shell imports the module unconditionally from quick settings. Keep the
# module present, while SignalStrengthInfo reads iOS reachability directly from
# MobileShell's ShellUtil provider to avoid a QML module cycle.
python3 - "$src/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
block = r'''

set(IOS_PLASMA_MM_STUB_DIR "${CMAKE_CURRENT_BINARY_DIR}/ios-plasma-mm-stub")
file(MAKE_DIRECTORY "${IOS_PLASMA_MM_STUB_DIR}")
file(WRITE "${IOS_PLASMA_MM_STUB_DIR}/qmldir" "module org.kde.plasma.mm\nsingleton SignalIndicator 1.0 SignalIndicator.qml\n")
file(WRITE "${IOS_PLASMA_MM_STUB_DIR}/SignalIndicator.qml" [=[
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
]=])
install(DIRECTORY "${IOS_PLASMA_MM_STUB_DIR}/" DESTINATION ${KDE_INSTALL_QMLDIR}/org/kde/plasma/mm)
'''
if "IOS_PLASMA_MM_STUB_DIR" not in text:
    text += block
path.write_text(text)
PY
