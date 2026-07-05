#!/usr/bin/env bash
# plasma-workspace-ios-fixes.sh — first-light source trims for plasmashell on iOS.
set -euo pipefail

src=${1:?usage: plasma-workspace-ios-fixes.sh <plasma-workspace-source-dir>}

cat > "$src/shell/config-X11.h" <<'EOF'
#pragma once
#define HAVE_X11 0
EOF

python3 - "$src/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

text = text.replace("CoreAddons KIO Prison Package\n                    GuiAddons Archive ItemModels IconThemes UnitConversion TextEditor StatusNotifierItem",
                    "CoreAddons KIO Package Solid\n                    GuiAddons Archive ItemModels IconThemes UnitConversion StatusNotifierItem")
for old, new in [
    ("find_package(Plasma5Support ${PROJECT_DEP_VERSION} REQUIRED)", "find_package(Plasma5Support ${PROJECT_DEP_VERSION})"),
    ("find_package(KSysGuard CONFIG REQUIRED)", "find_package(KSysGuard CONFIG)"),
    ("pkg_check_modules(QALCULATE libqalculate>2.0 REQUIRED IMPORTED_TARGET)", "pkg_check_modules(QALCULATE libqalculate>2.0 IMPORTED_TARGET)"),
    ("find_package(KF6Screen CONFIG REQUIRED)", "find_package(KF6Screen CONFIG)"),
    ("find_package(KScreenLocker 5.13.80 REQUIRED)", "find_package(KScreenLocker 5.13.80)"),
    ("find_package(ScreenSaverDBusInterface CONFIG REQUIRED)", "find_package(ScreenSaverDBusInterface CONFIG)"),
    ("find_package(Phonon4Qt6 4.6.60 REQUIRED NO_MODULE)", "find_package(Phonon4Qt6 4.6.60 NO_MODULE)"),
    ("TYPE REQUIRED)", "TYPE OPTIONAL)"),
    ("find_package(UDev REQUIRED)", "find_package(UDev)"),
]:
    text = text.replace(old, new)

text = text.replace('PROPERTIES DESCRIPTION "Unicode and Globalization support for software applications"\n        TYPE REQUIRED',
                    'PROPERTIES DESCRIPTION "Unicode and Globalization support for software applications"\n        TYPE OPTIONAL')

keep = {
    "applets",
    "dataengines",
    "kcms",
    "startkde",
    "lookandfeel",
    "logout-greeter",
    "libnotificationmanager",
    "libkworkspace",
    "libdbusmenuqt",
    "libtaskmanager",
    "menu",
    "components",
    "plasma-windowed",
    "shell",
    "statusnotifierwatcher",
    "themes",
    "wallpapers",
    "kioworkers",
}

def repl(match: re.Match[str]) -> str:
    name = match.group(1)
    if name in keep or name in {"doc"}:
        return match.group(0)
    return f"# ios-firstlight-skip: {match.group(0)}"

text = re.sub(r"^add_subdirectory\(([^)]+)\)", repl, text, flags=re.M)
text = re.sub(r"^ecm_optional_add_subdirectory\(([^)]+)\)",
              lambda m: f"# ios-firstlight-skip: {m.group(0)}", text, flags=re.M)

path.write_text(text)
PY

python3 - "$src/dataengines/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(
    r"^add_subdirectory\(([^)]+)\)",
    lambda m: m.group(0) if m.group(1) in {"time", "powermanagement"} else f"# ios-real-desktop-skip: {m.group(0)}",
    text,
    flags=re.M,
)
text = re.sub(
    r"^if \(PlasmaActivities_FOUND\)\n\s*add_subdirectory\(activities\)\nendif \(\)",
    "# ios-real-desktop-skip: PlasmaActivities dataengine",
    text,
    flags=re.M,
)
text = re.sub(
    r"^if \(KF6NetworkManagerQt_FOUND\)\n\s*add_subdirectory\(geolocation\)\nendif \(\)",
    "# ios-real-desktop-skip: NetworkManager geolocation dataengine",
    text,
    flags=re.M,
)
path.write_text(text)
PY

python3 - "$src/applets/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
keep_subdirs = {"digital-clock", "kicker", "notifications", "systemtray"}
keep_packages = {"org.kde.plasma.digitalclock", "org.kde.plasma.notifications"}

text = re.sub(
    r"^add_subdirectory\(([^)]+)\)",
    lambda m: m.group(0) if m.group(1) in keep_subdirs else f"# ios-firstlight-skip: {m.group(0)}",
    text,
    flags=re.M,
)
text = re.sub(
    r"^plasma_install_package\(([^)]+)\)",
    lambda m: m.group(0) if any(pkg in m.group(1) for pkg in keep_packages) else f"# ios-firstlight-skip: {m.group(0)}",
    text,
    flags=re.M,
)
path.write_text(text)
PY

python3 - "$src/components/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
keep = {
    "calendar",
    "containmentlayoutmanager",
    "dbus",
    "shellprivate",
    "keyboardlayout",
    "lookandfeelqml",
    "sessionsprivate",
    "trianglemousefilter",
    "workspace",
}
text = re.sub(r"^add_subdirectory\(([^)]+)\)",
              lambda m: m.group(0) if m.group(1) in keep else f"# ios-firstlight-skip: {m.group(0)}",
              text, flags=re.M)
path.write_text(text)
PY

python3 - "$src/kcms/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
keep = {
    "krdb",
    "desktoptheme",
    "icons",
    "style",
    "lookandfeel",
    "colors",
    "wallpaper",
}
text = re.sub(
    r"^add_subdirectory\(\s*([^) ]+)\s*\)",
    lambda m: m.group(0) if m.group(1) in keep else f"# ios-kcm-wave-skip: {m.group(0)}",
    text,
    flags=re.M,
)
text = re.sub(
    r"^if\(KF6UserFeedback_FOUND\)\n\s*add_subdirectory\(feedback\)\nendif\(\)",
    "# ios-kcm-wave-skip: feedback KCM needs KF6UserFeedback",
    text,
    flags=re.M,
)
text = re.sub(
    r"^if\(X11_Xcursor_FOUND\)\n\s*add_subdirectory\(cursortheme\)\nendif\(\)",
    "# ios-kcm-wave-skip: cursor theme KCM is X11-specific",
    text,
    flags=re.M,
)
text = re.sub(
    r"^if\(FONTCONFIG_FOUND\)\n\s*add_subdirectory\( kfontinst \)\n\s*add_subdirectory\( fonts \)\nendif\(\)",
    "# ios-kcm-wave-skip: font KCMs need a separate non-X11 pass",
    text,
    flags=re.M,
)
path.write_text(text)
PY

python3 - "$src/startkde/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
path.write_text("""add_subdirectory(plasmaautostart)
add_subdirectory(plasma-shutdown)
""")
PY

python3 - "$src/kcms/krdb/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    "target_link_libraries(krdb PRIVATE Qt::Widgets Qt::DBus KF6::CoreAddons KF6::DBusAddons KF6::GuiAddons KF6::I18n KF6::WindowSystem KF6::ConfigWidgets X11::X11 Qt::GuiPrivate)",
    "target_link_libraries(krdb PRIVATE Qt::Widgets Qt::DBus KF6::CoreAddons KF6::DBusAddons KF6::GuiAddons KF6::I18n KF6::WindowSystem KF6::ConfigWidgets)\nif(HAVE_X11)\n    target_link_libraries(krdb PRIVATE X11::X11 Qt::GuiPrivate)\nendif()",
)
path.write_text(text)
PY

python3 - "$src/kcms/colors/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("if(HAVE_X11)\n    target_link_libraries(kcm_colors PRIVATE X11::X11 Qt::GuiPrivate)\nendif()\n", "")
text = text.replace("    Qt::GuiPrivate\n", "")
text = text.replace("    X11::X11\n", "")
path.write_text(text)
PY

python3 - "$src/kcms/lookandfeel/kcm.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#include <private/qtx11extras_p.h>\n", "#if defined(HAVE_X11) && HAVE_X11\n#include <private/qtx11extras_p.h>\n#endif\n")
text = text.replace("#include <X11/Xlib.h>\n", "#if defined(HAVE_X11) && HAVE_X11\n#include <X11/Xlib.h>\n#endif\n")
path.write_text(text)
PY

python3 - "$src/components/sessionsprivate/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
if "xios fallback ScreenSaver DBus interface" not in text:
    text = text.replace(
        "set(sessionsprivateplugin_SRCS\n",
        "if(NOT SCREENSAVER_DBUS_INTERFACE)\n"
        "    # xios fallback ScreenSaver DBus interface until kscreenlocker is ported.\n"
        "    set(SCREENSAVER_DBUS_INTERFACE \"${plasma-workspace_SOURCE_DIR}/iosc-dbus-interfaces/kf6_org.freedesktop.ScreenSaver.xml\")\n"
        "endif()\n\n"
        "set(sessionsprivateplugin_SRCS\n",
    )
path.write_text(text)
PY

python3 - "$src/logout-greeter/CMakeLists.txt" "$src/logout-greeter/shutdowndlg.cpp" <<'PY'
import re
import sys
from pathlib import Path

cmake = Path(sys.argv[1])
text = cmake.read_text()
text = text.replace("    X11::X11\n", "")
if "target_link_libraries(ksmserver-logout-greeter Qt::GuiPrivate)" in text:
    text = text.replace("target_link_libraries(ksmserver-logout-greeter Qt::GuiPrivate)", "if(HAVE_X11)\n    target_link_libraries(ksmserver-logout-greeter X11::X11 Qt::GuiPrivate)\nendif()")
cmake.write_text(text)

source = Path(sys.argv[2])
text = source.read_text()
text = text.replace("\n#include <config-workspace.h>\n", "\n")
text = text.replace('#include "shutdowndlg.h"\n', '#include "shutdowndlg.h"\n#include <config-workspace.h>\n')
for header in ["#include <private/qtx11extras_p.h>\n", "#include <KX11Extras>\n", "#include <netwm.h>\n"]:
    text = text.replace(header, f"#if defined(HAVE_X11) && HAVE_X11\n{header}#endif\n")
text = text.replace("#include <X11/Xatom.h>\n#include <X11/Xutil.h>\n#include <fixx11h.h>\n", "#if defined(HAVE_X11) && HAVE_X11\n#include <X11/Xatom.h>\n#include <X11/Xutil.h>\n#include <fixx11h.h>\n#endif\n")
for header in ["#include <private/qtx11extras_p.h>\n", "#include <KX11Extras>\n", "#include <netwm.h>\n"]:
    text = re.sub(
        rf"(?:#if defined\(HAVE_X11\) && HAVE_X11\n)+{re.escape(header)}(?:#endif\n)+",
        f"#if defined(HAVE_X11) && HAVE_X11\n{header}#endif\n",
        text,
    )
text = re.sub(
    r"(?:#if defined\(HAVE_X11\) && HAVE_X11\n)+#include <X11/Xatom\.h>\n#include <X11/Xutil\.h>\n#include <fixx11h\.h>\n(?:#endif\n)+",
    "#if defined(HAVE_X11) && HAVE_X11\n#include <X11/Xatom.h>\n#include <X11/Xutil.h>\n#include <fixx11h.h>\n#endif\n",
    text,
)
old = """    if (KWindowSystem::isPlatformX11()) {
        XChangeProperty(QX11Info::display(),
                        winId(),
                        XInternAtom(QX11Info::display(), "WM_WINDOW_ROLE", False),
                        XA_STRING,
                        8,
                        PropModeReplace,
                        (unsigned char *)"logoutdialog",
                        strlen("logoutdialog"));

        XClassHint classHint;
        classHint.res_name = const_cast<char *>("ksmserver-logout-greeter");
        classHint.res_class = const_cast<char *>("ksmserver-logout-greeter");
        XSetClassHint(QX11Info::display(), winId(), &classHint);
        KX11Extras::setState(winId(), NET::SkipTaskbar | NET::SkipPager | NET::SkipSwitcher);
    }
"""
new = """#if defined(HAVE_X11) && HAVE_X11
    if (KWindowSystem::isPlatformX11()) {
        XChangeProperty(QX11Info::display(),
                        winId(),
                        XInternAtom(QX11Info::display(), "WM_WINDOW_ROLE", False),
                        XA_STRING,
                        8,
                        PropModeReplace,
                        (unsigned char *)"logoutdialog",
                        strlen("logoutdialog"));

        XClassHint classHint;
        classHint.res_name = const_cast<char *>("ksmserver-logout-greeter");
        classHint.res_class = const_cast<char *>("ksmserver-logout-greeter");
        XSetClassHint(QX11Info::display(), winId(), &classHint);
        KX11Extras::setState(winId(), NET::SkipTaskbar | NET::SkipPager | NET::SkipSwitcher);
    }
#endif
"""
if old in text:
    text = text.replace(old, new)
elif "KX11Extras::setState(winId(), NET::SkipTaskbar | NET::SkipPager | NET::SkipSwitcher);" not in text:
    raise SystemExit("logout greeter X11 window metadata block not found")
old = """    if (KX11Extras::compositingActive()) {
        // TODO: reenable window mask when we are without composite?
        //        clearMask();
    } else {
        //        setMask(m_view->mask());
    }
"""
new = """#if defined(HAVE_X11) && HAVE_X11
    if (KX11Extras::compositingActive()) {
        // TODO: reenable window mask when we are without composite?
        //        clearMask();
    } else {
        //        setMask(m_view->mask());
    }
#endif
"""
if old in text:
    text = text.replace(old, new)
elif "KX11Extras::compositingActive()" not in text:
    raise SystemExit("logout greeter compositing block not found")
source.write_text(text)
PY

for layout in \
  "$src/lookandfeel/org.kde.breeze/contents/layouts/org.kde.plasma.desktop-layout.js" \
  "$src/lookandfeel/org.kde.breezedark/contents/layouts/org.kde.plasma.desktop-layout.js" \
  "$src/lookandfeel/org.kde.breezetwilight/contents/layouts/org.kde.plasma.desktop-layout.js"; do
  [ -f "$layout" ] || continue
  python3 - "$layout" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(
    r"desktopsArray\[j\]\.wallpaperPlugin = 'org\.kde\.(?:image|color)';",
    """desktopsArray[j].wallpaperPlugin = 'org.kde.image';
    desktopsArray[j].currentConfigGroup = Array('Wallpaper', 'org.kde.image', 'General');
    desktopsArray[j].writeConfig('Image', 'file:///var/jb/usr/share/backgrounds/xios/xios-default.jpg');
    desktopsArray[j].writeConfig('PreviewImage', 'file:///var/jb/usr/share/backgrounds/xios/xios-default.jpg');
    desktopsArray[j].writeConfig('FillMode', 2);""",
    text,
)
path.write_text(text)
PY
done

perl -0pi -e 's/add_subdirectory\(test\)/# ios-firstlight-skip: add_subdirectory(test)/g' "$src/libdbusmenuqt/CMakeLists.txt"
perl -0pi -e 's/add_subdirectory\(kconf_update\)/# ios-firstlight-skip: add_subdirectory(kconf_update)/g' "$src/shell/CMakeLists.txt"
perl -0pi -e 's/add_subdirectory\(wallpaperfileitemactionplugin\)/# ios-firstlight-skip: add_subdirectory(wallpaperfileitemactionplugin)/g' "$src/wallpapers/image/CMakeLists.txt"

python3 - "$src/kioworkers/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(
    r"^add_subdirectory\(([^)]+)\)",
    lambda m: m.group(0) if m.group(1) == "desktop" else f"# ios-firstlight-skip: {m.group(0)}",
    text,
    flags=re.M,
)
path.write_text(text)
PY

python3 - "$src/kioworkers/desktop/CMakeLists.txt" "$src/kioworkers/desktop/kio_desktop.cpp" "$src/kioworkers/desktop/desktopnotifier.cpp" <<'PY'
import sys
from pathlib import Path

cmake = Path(sys.argv[1])
text = cmake.read_text()
marker = "# iOS cross-build: use KIO's generated KDirNotify header from the staged source tree"
if marker not in text:
    text = text.replace(
        "include_directories(${CMAKE_CURRENT_BINARY_DIR})\n",
        "include_directories(${CMAKE_CURRENT_BINARY_DIR})\n"
        f"{marker}\n"
        "include_directories(${plasma-workspace_SOURCE_DIR}/../kio/src/core)\n",
    )
cmake.write_text(text)

kio = Path(sys.argv[2])
text = kio.read_text()
text = text.replace("#include <KDirNotify>", "#include <kdirnotify.h>")
text = text.replace(
    """    org::kde::kded6 kded(QStringLiteral("org.kde.kded6"), QStringLiteral("/kded"), QDBusConnection::sessionBus());
    auto pending = kded.loadModule("desktopnotifier");
    pending.waitForFinished();
""",
    """    // iOS first-light skips the desktopnotifier KDED sidecar; desktop:/ remains usable.
""",
)
kio.write_text(text)

notifier = Path(sys.argv[3])
text = notifier.read_text()
text = text.replace("#include <KDirNotify>", "#include <kdirnotify.h>")
notifier.write_text(text)
PY

python3 - "$src/shell/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
moc_marker = "# iOS cross-build: qdbusxml2cpp sources include generated moc files"
if moc_marker not in text:
    needle = "qt_add_dbus_interface(plasma_shell_SRCS ${krunner_xml} krunner_interface)\n\n\n"
    if needle not in text:
        raise SystemExit("plasmashell DBus interface marker not found")
    text = text.replace(
        needle,
        needle
        + f"""{moc_marker}; make the dependency explicit so Ninja does not race
# the qdbusxml2cpp compile before moc generation.
set_source_files_properties(
    ${{CMAKE_CURRENT_BINARY_DIR}}/plasmashelladaptor.cpp
    PROPERTIES OBJECT_DEPENDS ${{CMAKE_CURRENT_BINARY_DIR}}/moc_plasmashelladaptor.cpp
)
set_source_files_properties(
    ${{CMAKE_CURRENT_BINARY_DIR}}/krunner_interface.cpp
    PROPERTIES OBJECT_DEPENDS ${{CMAKE_CURRENT_BINARY_DIR}}/moc_krunner_interface.cpp
)

""",
    )
marker = "# iOS first-light QML import shims"
if marker not in text:
    needle = "install( FILES dbus/org.kde.PlasmaShell.xml DESTINATION ${KDE_INSTALL_DBUSINTERFACEDIR} )\n"
    if needle not in text:
        raise SystemExit("plasmashell DBus install marker not found")
    text = text.replace(
        needle,
        needle
        + f"""
{marker}: these modules are registered by plasmashell at runtime, but QML still
# needs importable qmldir markers when resolving upstream shell package imports.
file(MAKE_DIRECTORY ${{CMAKE_CURRENT_BINARY_DIR}}/ios-qml/org/kde/plasma/shell/panel)
file(WRITE ${{CMAKE_CURRENT_BINARY_DIR}}/ios-qml/org/kde/plasma/shell/qmldir "module org.kde.plasma.shell\\n")
file(WRITE ${{CMAKE_CURRENT_BINARY_DIR}}/ios-qml/org/kde/plasma/shell/panel/qmldir "module org.kde.plasma.shell.panel\\n")
install(FILES ${{CMAKE_CURRENT_BINARY_DIR}}/ios-qml/org/kde/plasma/shell/qmldir DESTINATION ${{KDE_INSTALL_QMLDIR}}/org/kde/plasma/shell)
install(FILES ${{CMAKE_CURRENT_BINARY_DIR}}/ios-qml/org/kde/plasma/shell/panel/qmldir DESTINATION ${{KDE_INSTALL_QMLDIR}}/org/kde/plasma/shell/panel)
""",
    )
path.write_text(text)
PY

python3 - "$src/libnotificationmanager/CMakeLists.txt" "$src/libnotificationmanager/mirroredscreenstracker_p.h" <<'PY'
import sys
from pathlib import Path

cmake = Path(sys.argv[1])
text = cmake.read_text()
text = text.replace("        KF6::Screen\n", "")
cmake.write_text(text)

header = Path(sys.argv[2])
text = header.read_text()
text = text.replace("#include <KScreen/Config>\n", "")
header.write_text(text)
PY

python3 - "$src/libnotificationmanager/server.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#include <KStartupInfo>\n", "#if !defined(__APPLE__)\n#include <KStartupInfo>\n#endif\n")
text = text.replace(
    """        KStartupInfoId startupId;
        startupId.initId();

        Q_EMIT d->ActivationToken(notificationId, QString::fromUtf8(startupId.id()));
""",
    """#if !defined(__APPLE__)
        KStartupInfoId startupId;
        startupId.initId();

        Q_EMIT d->ActivationToken(notificationId, QString::fromUtf8(startupId.id()));
#else
        Q_EMIT d->ActivationToken(notificationId, QString());
#endif
""",
)
path.write_text(text)
PY

python3 - "$src/applets/notifications/notificationapplet.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#include <KX11Extras>\n", "#if !defined(__APPLE__)\n#include <KX11Extras>\n#endif\n")
text = text.replace(
    """    if (window && window->winId()) {
        KX11Extras::forceActiveWindow(window->winId());
    }
""",
    """#if !defined(__APPLE__)
    if (window && window->winId()) {
        KX11Extras::forceActiveWindow(window->winId());
    }
#else
    if (window) {
        window->requestActivate();
    }
#endif
""",
)
path.write_text(text)
PY

python3 - "$src/applets/digital-clock/plugin/CMakeLists.txt" "$src/applets/digital-clock/plugin/timezonesi18n.h" "$src/applets/digital-clock/plugin/timezonesi18n.cpp" <<'PY'
import sys
from pathlib import Path

cmake = Path(sys.argv[1])
text = cmake.read_text()
text = text.replace("        ICU::i18n\n", "")
text = text.replace("        ICU::uc\n", "")
text = text.replace("        Qt::Qml\n        Qt::Widgets", "        Qt::Qml\n        Qt::DBus\n        Qt::Widgets")
cmake.write_text(text)

header = Path(sys.argv[2])
text = header.read_text()
text = text.replace("#include <unicode/tznames.h>\n\n", "")
text = text.replace("    QScopedPointer<icu::TimeZoneNames> m_tzNames;\n", "")
header.write_text(text)

source = Path(sys.argv[3])
text = source.read_text()
text = text.replace("#include <unicode/localebuilder.h>\n\n", "")
text = text.replace(
    """    if (!m_tzNames) {
        return timezoneId;
    }

    icu::UnicodeString result;
    const auto &cityName = m_tzNames->getExemplarLocationName(icu::UnicodeString::fromUTF8(icu::StringPiece(timezoneId.toStdString())), result);

    return cityName.isBogus() ? timezoneId : QStringView(cityName.getBuffer(), cityName.length()).toString();
""",
    """    const QString city = timezoneId.section(QLatin1Char('/'), -1).replace(QLatin1Char('_'), QLatin1Char(' '));
    return city.isEmpty() ? timezoneId : city;
""",
)
text = text.replace(
    """    const auto locale = icu::Locale(QLocale::system().name().toLatin1());
    UErrorCode error = U_ZERO_ERROR;
    m_tzNames.reset(icu::TimeZoneNames::createInstance(locale, error));
    if (!U_SUCCESS(error)) {
        qWarning() << "failed to create timezone names:" << u_errorName(error);
    }

""",
    "",
)
source.write_text(text)
PY

python3 - "$src/applets/kicker/plugin/rootmodel.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    """    , m_favorites(new KAStatsFavoritesModel(this))
    , m_systemModel(nullptr)
""",
    """    , m_favorites(new KAStatsFavoritesModel(this))
    , m_systemModel(new SystemModel(this))
""",
)
text = text.replace(
    """    m_systemModel = new SystemModel(this);
    QObject::connect(m_systemModel, &SystemModel::sessionManagementStateChanged, this, &RootModel::refresh);
""",
    """    if (!m_systemModel) {
        m_systemModel = new SystemModel(this);
    }
    QObject::disconnect(m_systemModel, &SystemModel::sessionManagementStateChanged, this, &RootModel::refresh);
    QObject::connect(m_systemModel, &SystemModel::sessionManagementStateChanged, this, &RootModel::refresh);
""",
)
path.write_text(text)
PY

python3 - "$src/shell/main.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
marker = 'org.kde.KActivities.core.disableAutostart'
if marker not in text:
    text = text.replace(
        "    QApplication app(argc, argv);\n",
        """    QApplication app(argc, argv);
#if defined(__APPLE__)
    if (qEnvironmentVariableIsSet("XIOS_KDE_NO_KAMD")) {
        app.setProperty("org.kde.KActivities.core.disableAutostart", true);
    }
#endif
""",
    )
path.write_text(text)
PY

mkdir -p "$src/iosc-dbus-interfaces"
cat > "$src/iosc-dbus-interfaces/kf6_org.freedesktop.ScreenSaver.xml" <<'XML'
<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
 "https://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
  <interface name="org.freedesktop.ScreenSaver">
    <method name="Lock"/>
    <method name="GetActive">
      <arg name="active" type="b" direction="out"/>
    </method>
    <signal name="ActiveChanged">
      <arg name="active" type="b"/>
    </signal>
  </interface>
</node>
XML
python3 - "$src/libkworkspace/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("set(kworkspace_LIB_SRCS kdisplaymanager.cpp",
                    'set(KSCREENLOCKER_DBUS_INTERFACES_DIR "${plasma-workspace_SOURCE_DIR}/iosc-dbus-interfaces")\nset(kworkspace_LIB_SRCS kdisplaymanager.cpp')
path.write_text(text)
PY

python3 - "$src/libkworkspace/outputorderwatcher.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
start = text.index("\nX11OutputOrderWatcher::X11OutputOrderWatcher")
end = text.index("\nWaylandOutputOrderWatcher::WaylandOutputOrderWatcher")
x11_impl = text[start:end]
if "#if defined(HAVE_X11) && HAVE_X11" not in x11_impl:
    text = text[:start] + "\n#if defined(HAVE_X11) && HAVE_X11" + x11_impl + "#endif\n" + text[end:]
path.write_text(text)
PY

python3 - "$src/libkworkspace/sessionmanagementbackend.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    "#include <QMutex>\n#include <QMutexLocker>\n",
    "#include <QMutex>\n#include <QMutexLocker>\n#include <QFileInfo>\n#include <QProcess>\n#include <QStandardPaths>\n#include <QStringList>\n",
)
marker = "static SessionBackend *s_backend = nullptr;\n\n"
shim = r'''
#if defined(__APPLE__)
static QString xiosSessionBinary()
{
    const QStringList candidates = {
        QStringLiteral("/var/jb/usr/local/bin/xios-session"),
        QStringLiteral("/var/jb/usr/bin/xios-session"),
        QStringLiteral("/usr/local/bin/xios-session"),
        QStringLiteral("/usr/bin/xios-session"),
        QStandardPaths::findExecutable(QStringLiteral("xios-session")),
    };
    for (const QString &candidate : candidates) {
        if (!candidate.isEmpty() && QFileInfo(candidate).isExecutable()) {
            return candidate;
        }
    }
    return QString();
}

static void runXiosSession(const QStringList &arguments)
{
    const QString program = xiosSessionBinary();
    if (program.isEmpty()) {
        qWarning() << "xios-session is not installed; cannot perform session action" << arguments;
        return;
    }
    if (!QProcess::startDetached(program, arguments)) {
        qWarning() << "failed to start xios-session" << arguments;
    }
}

class XiosSessionBackend final : public SessionBackend
{
public:
    static bool exists()
    {
        return true;
    }

    SessionManagement::State state() const override
    {
        return SessionManagement::State::Ready;
    }

    void shutdown() override
    {
        runXiosSession({QStringLiteral("stop")});
    }
    void reboot() override
    {
        runXiosSession({QStringLiteral("stop")});
    }
    void suspend() override
    {
    }
    void hybridSuspend() override
    {
    }
    void hibernate() override
    {
    }
    void suspendThenHibernate() override
    {
    }

    bool canShutdown() const override
    {
        return false;
    }
    bool canReboot() const override
    {
        return false;
    }
    bool canSuspend() const override
    {
        return false;
    }
    bool canHybridSuspend() const override
    {
        return false;
    }
    bool canHibernate() const override
    {
        return false;
    }
    bool canSuspendThenHibernate() const override
    {
        return false;
    }
};
#endif

'''
if shim.strip() not in text:
    if marker not in text:
        raise SystemExit("session backend singleton marker not found")
    text = text.replace(marker, marker + shim)
old = """    if (qEnvironmentVariableIntValue("PLASMA_SESSION_GUI_TEST")) {
        s_backend = new TestSessionBackend();
    } else if (LogindSessionBackend::exists()) {
        s_backend = new LogindSessionBackend();
    } else {
        s_backend = new DummySessionBackend();
    }
"""
new = """    if (qEnvironmentVariableIntValue("PLASMA_SESSION_GUI_TEST")) {
        s_backend = new TestSessionBackend();
    } else if (LogindSessionBackend::exists()) {
        s_backend = new LogindSessionBackend();
#if defined(__APPLE__)
    } else if (XiosSessionBackend::exists()) {
        s_backend = new XiosSessionBackend();
#endif
    } else {
        s_backend = new DummySessionBackend();
    }
"""
if old in text:
    text = text.replace(old, new)
elif "XiosSessionBackend::exists()" not in text:
    raise SystemExit("SessionBackend::self selection block not found")
path.write_text(text)
PY

python3 - "$src/startkde/plasma-shutdown/shutdown.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
old = """    if (m_shutdownType == KWorkSpace::ShutdownTypeHalt) {
        SessionBackend::self()->shutdown();
    } else if (m_shutdownType == KWorkSpace::ShutdownTypeReboot) {
        SessionBackend::self()->reboot();
    } else { // logout
        qApp->quit();
    }
"""
new = """    if (m_shutdownType == KWorkSpace::ShutdownTypeHalt) {
        SessionBackend::self()->shutdown();
    } else if (m_shutdownType == KWorkSpace::ShutdownTypeReboot) {
        SessionBackend::self()->reboot();
    } else { // logout
#if defined(__APPLE__)
        SessionBackend::self()->shutdown();
#else
        qApp->quit();
#endif
    }
"""
if old in text:
    text = text.replace(old, new)
elif "SessionBackend::self()->shutdown();" not in text:
    raise SystemExit("plasma-shutdown logoutComplete block not found")
path.write_text(text)
PY

python3 - "$src/libtaskmanager/virtualdesktopinfo.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#include <KX11Extras>\n", "#if defined(HAVE_X11) && HAVE_X11\n#include <KX11Extras>\n#endif\n")
start = text.index("\nnamespace X11Info\n")
end = text.index("\nnamespace TaskManager\n")
x11_info = text[start:end]
if "#if defined(HAVE_X11) && HAVE_X11" not in x11_info:
    text = text[:start] + "\n#if defined(HAVE_X11) && HAVE_X11" + x11_info + "#endif\n" + text[end:]
path.write_text(text)
PY

python3 - "$src/libtaskmanager/waylandtasksmodel.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
old = """        int pipeFds[2];
        if (pipe2(pipeFds, O_CLOEXEC) != 0) {
            qCWarning(TASKMANAGER_DEBUG) << "failed creating pipe";
            return;
        }
"""
new = """        int pipeFds[2];
#if defined(__APPLE__)
        if (pipe(pipeFds) != 0) {
            qCWarning(TASKMANAGER_DEBUG) << "failed creating pipe";
            return;
        }
        fcntl(pipeFds[0], F_SETFD, FD_CLOEXEC);
        fcntl(pipeFds[1], F_SETFD, FD_CLOEXEC);
#else
        if (pipe2(pipeFds, O_CLOEXEC) != 0) {
            qCWarning(TASKMANAGER_DEBUG) << "failed creating pipe";
            return;
        }
#endif
"""
if old in text:
    text = text.replace(old, new)
elif "if (pipe(pipeFds) != 0)" not in text:
    raise SystemExit("pipe2 block not found")
path.write_text(text)
PY

python3 - "$src/applets/kicker/plugin/dashboardwindow.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#include <KX11Extras>\n", "#if defined(HAVE_X11) && HAVE_X11\n#include <KX11Extras>\n#endif\n")
text = text.replace(
    """        showFullScreen();
        KX11Extras::forceActiveWindow(winId());
""",
    """        showFullScreen();
#if defined(HAVE_X11) && HAVE_X11
        if (KWindowSystem::isPlatformX11()) {
            KX11Extras::forceActiveWindow(winId());
        } else
#endif
        {
            requestActivate();
        }
""",
)
text = text.replace(
    """            if (KWindowSystem::isPlatformX11()) {
                KX11Extras::setState(winId(), NET::SkipTaskbar | NET::SkipPager | NET::SkipSwitcher);
            } else {
                if (m_plasmashell) {
                    auto *surface = KWayland::Client::Surface::fromQtWinId(winId());
                    auto *plasmashellSurface = KWayland::Client::PlasmaShellSurface::get(surface);

                    if (!plasmashellSurface) {
                        plasmashellSurface = m_plasmashell->createSurface(surface, this);
                    }

                    plasmashellSurface->setSkipSwitcher(true);
                    plasmashellSurface->setSkipTaskbar(true);
                }
            }
""",
    """#if defined(HAVE_X11) && HAVE_X11
            if (KWindowSystem::isPlatformX11()) {
                KX11Extras::setState(winId(), NET::SkipTaskbar | NET::SkipPager | NET::SkipSwitcher);
            } else
#endif
            {
                if (m_plasmashell) {
                    auto *surface = KWayland::Client::Surface::fromQtWinId(winId());
                    auto *plasmashellSurface = KWayland::Client::PlasmaShellSurface::get(surface);

                    if (!plasmashellSurface) {
                        plasmashellSurface = m_plasmashell->createSurface(surface, this);
                    }

                    plasmashellSurface->setSkipSwitcher(true);
                    plasmashellSurface->setSkipTaskbar(true);
                }
            }
""",
)
text = text.replace(
    """        if (isVisible()) {
            KX11Extras::forceActiveWindow(winId());
        }
""",
    """        if (isVisible()) {
#if defined(HAVE_X11) && HAVE_X11
            if (KWindowSystem::isPlatformX11()) {
                KX11Extras::forceActiveWindow(winId());
            } else
#endif
            {
                requestActivate();
            }
        }
""",
)
path.write_text(text)
PY

python3 - "$src/applets/kicker/plugin/windowsystem.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#include <KX11Extras>\n", "#if defined(HAVE_X11) && HAVE_X11\n#include <KX11Extras>\n#endif\n")
text = text.replace(
    """    KX11Extras::forceActiveWindow(item->window()->winId());
""",
    """#if defined(HAVE_X11) && HAVE_X11
    if (KWindowSystem::isPlatformX11()) {
        KX11Extras::forceActiveWindow(item->window()->winId());
        return;
    }
#endif
    item->window()->requestActivate();
""",
)
path.write_text(text)
PY

python3 - "$src/shell/panelview.cpp" "$src/shell/shellcorona.cpp" <<'PY'
import sys
from pathlib import Path

for name in sys.argv[1:]:
    path = Path(name)
    text = path.read_text()
    text = text.replace("#include <KX11Extras>\n", "#if defined(HAVE_X11) && HAVE_X11\n#include <KX11Extras>\n#endif\n")
    text = text.replace("""        if (!KWindowSystem::isPlatformX11() || KX11Extras::compositingActive()) {
            setMask(screenPanelRect);
        } else {
            setMask(mask);
        }
""", """#if defined(HAVE_X11) && HAVE_X11
        if (!KWindowSystem::isPlatformX11() || KX11Extras::compositingActive()) {
            setMask(screenPanelRect);
        } else {
            setMask(mask);
        }
#else
        setMask(screenPanelRect);
#endif
""")
    text = text.replace("""        if (KWindowSystem::isPlatformX11()) {
            KX11Extras::forceActiveWindow(winId());
        } else {
            showTemporarily();
        }
""", """#if defined(HAVE_X11) && HAVE_X11
        if (KWindowSystem::isPlatformX11()) {
            KX11Extras::forceActiveWindow(winId());
        } else
#endif
        {
            showTemporarily();
        }
""")
    path.write_text(text)
PY

python3 - "$src/shell/panelconfigview.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#if HAVE_X11\n#include <KX11Extras>\n#endif", "#if defined(HAVE_X11) && HAVE_X11\n#include <KX11Extras>\n#endif")
text = text.replace("""    if (KWindowSystem::isPlatformX11()) {
        KX11Extras::setType(winId(), NET::Dock);
        KX11Extras::setState(winId(), NET::KeepAbove);
        switch (m_containment->location()) {
        case Plasma::Types::TopEdge:
            setPosition(available.topLeft() + screen()->geometry().topLeft());
            break;
        case Plasma::Types::LeftEdge:
            setPosition(available.topLeft() + screen()->geometry().topLeft());
            break;
        case Plasma::Types::RightEdge:
            setPosition(available.topLeft() + screen()->geometry().topRight() - QPoint(width(), 0));
            break;
        case Plasma::Types::BottomEdge:
        default:
            setPosition(available.bottomLeft() + screen()->geometry().topLeft() - QPoint(0, height()));
        }
    } else if (m_layerWindow) {
""", """#if defined(HAVE_X11) && HAVE_X11
    if (KWindowSystem::isPlatformX11()) {
        KX11Extras::setType(winId(), NET::Dock);
        KX11Extras::setState(winId(), NET::KeepAbove);
        switch (m_containment->location()) {
        case Plasma::Types::TopEdge:
            setPosition(available.topLeft() + screen()->geometry().topLeft());
            break;
        case Plasma::Types::LeftEdge:
            setPosition(available.topLeft() + screen()->geometry().topLeft());
            break;
        case Plasma::Types::RightEdge:
            setPosition(available.topLeft() + screen()->geometry().topRight() - QPoint(width(), 0));
            break;
        case Plasma::Types::BottomEdge:
        default:
            setPosition(available.bottomLeft() + screen()->geometry().topLeft() - QPoint(0, height()));
        }
    } else
#endif
    if (m_layerWindow) {
""")
text = text.replace("""    if (KWindowSystem::isPlatformX11()) {
        KX11Extras::setType(winId(), NET::AppletPopup);
    } else {
        PlasmaShellWaylandIntegration::get(this)->setRole(QtWayland::org_kde_plasma_surface::role::role_appletpopup);
    }
""", """#if defined(HAVE_X11) && HAVE_X11
    if (KWindowSystem::isPlatformX11()) {
        KX11Extras::setType(winId(), NET::AppletPopup);
    } else
#endif
    {
        PlasmaShellWaylandIntegration::get(this)->setRole(QtWayland::org_kde_plasma_surface::role::role_appletpopup);
    }
""")
path.write_text(text)
PY

python3 - "$src/shell/desktopview.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#include <qopenglshaderprogram.h>\n", "")
text = text.replace("#include <KStartupInfo>\n", "#if defined(HAVE_X11) && HAVE_X11\n#include <KStartupInfo>\n#endif\n")
text = text.replace("#include <KX11Extras>\n", "#if defined(HAVE_X11) && HAVE_X11\n#include <KX11Extras>\n#endif\n")
text = text.replace("""    if (KWindowSystem::isPlatformWayland()) {
        m_layerWindow = LayerShellQt::Window::get(this);
        m_layerWindow->setKeyboardInteractivity(LayerShellQt::Window::KeyboardInteractivityOnDemand);
        m_layerWindow->setExclusiveZone(-1);
        m_layerWindow->setLayer(LayerShellQt::Window::LayerBackground);
        m_layerWindow->setScope(QStringLiteral("desktop"));
        m_layerWindow->setCloseOnDismissed(false);
    } else {
        KX11Extras::setType(winId(), NET::Desktop);
        KX11Extras::setState(winId(), NET::KeepBelow);
    }
""", """    if (KWindowSystem::isPlatformWayland()) {
        m_layerWindow = LayerShellQt::Window::get(this);
        m_layerWindow->setKeyboardInteractivity(LayerShellQt::Window::KeyboardInteractivityOnDemand);
        m_layerWindow->setExclusiveZone(-1);
        m_layerWindow->setLayer(LayerShellQt::Window::LayerBackground);
        m_layerWindow->setScope(QStringLiteral("desktop"));
        m_layerWindow->setCloseOnDismissed(false);
    }
#if defined(HAVE_X11) && HAVE_X11
    else {
        KX11Extras::setType(winId(), NET::Desktop);
        KX11Extras::setState(winId(), NET::KeepBelow);
    }
#endif
""")
text = text.replace("""            if (window && qGuiApp->nativeInterface<QNativeInterface::QX11Application>()) {
                KStartupInfo::setNewStartupId(window, qgetenv("DESKTOP_STARTUP_ID"));
            }
""", """#if defined(HAVE_X11) && HAVE_X11
            if (window && qGuiApp->nativeInterface<QNativeInterface::QX11Application>()) {
                KStartupInfo::setNewStartupId(window, qgetenv("DESKTOP_STARTUP_ID"));
            }
#endif
""")
text = text.replace("""    if (window && qGuiApp->nativeInterface<QNativeInterface::QX11Application>()) {
        KStartupInfo::setNewStartupId(window, qgetenv("DESKTOP_STARTUP_ID"));
    }
""", """#if defined(HAVE_X11) && HAVE_X11
    if (window && qGuiApp->nativeInterface<QNativeInterface::QX11Application>()) {
        KStartupInfo::setNewStartupId(window, qgetenv("DESKTOP_STARTUP_ID"));
    }
#endif
""")
path.write_text(text)
PY

python3 - "$src/shell/shellcorona.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("""void ShellCorona::clearPreviousWindow()
{
    m_previousWId = 0;
    m_previousPlasmaWindow = nullptr;
}
""", """void ShellCorona::clearPreviousWindow()
{
#if defined(HAVE_X11) && HAVE_X11
    m_previousWId = 0;
#endif
    m_previousPlasmaWindow = nullptr;
}
""")
path.write_text(text)
PY

python3 - "$src/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(r"^([ \t]*)ecm_install_po_files_as_qm\(", r"\1# ios-bringup-no-linguist: ecm_install_po_files_as_qm(", text, flags=re.M)
path.write_text(text)
PY
