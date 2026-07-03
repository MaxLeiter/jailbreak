#!/usr/bin/env bash
# plasma-workspace-ios-fixes.sh — first-light source trims for plasmashell on iOS.
set -euo pipefail

src=${1:?usage: plasma-workspace-ios-fixes.sh <plasma-workspace-source-dir>}

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
    "lookandfeel",
    "libnotificationmanager",
    "libkworkspace",
    "libdbusmenuqt",
    "libtaskmanager",
    "components",
    "plasma-windowed",
    "shell",
    "statusnotifierwatcher",
    "themes",
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

python3 - "$src/components/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
keep = {"containmentlayoutmanager", "dbus", "shellprivate", "lookandfeelqml", "trianglemousefilter", "workspace"}
text = re.sub(r"^add_subdirectory\(([^)]+)\)",
              lambda m: m.group(0) if m.group(1) in keep else f"# ios-firstlight-skip: {m.group(0)}",
              text, flags=re.M)
path.write_text(text)
PY

perl -0pi -e 's/add_subdirectory\(test\)/# ios-firstlight-skip: add_subdirectory(test)/g' "$src/libdbusmenuqt/CMakeLists.txt"
perl -0pi -e 's/add_subdirectory\(packageplugins\)/# ios-firstlight-skip: add_subdirectory(packageplugins)/g' "$src/shell/CMakeLists.txt"
perl -0pi -e 's/add_subdirectory\(kconf_update\)/# ios-firstlight-skip: add_subdirectory(kconf_update)/g' "$src/shell/CMakeLists.txt"

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
if old not in text:
    raise SystemExit("pipe2 block not found")
text = text.replace(old, new)
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

sed -i '/^[[:space:]]*ecm_install_po_files_as_qm(/s/^/# ios-bringup-no-linguist: /' "$src/CMakeLists.txt"
