#!/usr/bin/env bash
set -euo pipefail
# xios_fixlib.Path: hunks on files Plasma 6.7 removed become logged no-ops instead of aborting.
export PYTHONPATH="$(cd "$(dirname "$0")" && pwd)${PYTHONPATH:+:$PYTHONPATH}"

src=${1:?usage: plasma-desktop-ios-fixes.sh <plasma-desktop-source-dir>}

python3 - "$src/CMakeLists.txt" <<'PY'
import re
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()

text = text.replace("""    DocTools
    I18n
""", """    I18n
""")
for old, new in [
    ("find_package(Plasma5Support ${PROJECT_DEP_VERSION} REQUIRED)", "find_package(Plasma5Support ${PROJECT_DEP_VERSION})"),
    ("find_package(LibNotificationManager ${PROJECT_DEP_VERSION} CONFIG REQUIRED)", "find_package(LibNotificationManager ${PROJECT_DEP_VERSION} CONFIG)"),
    ("find_package(LibColorCorrect ${PROJECT_DEP_VERSION} CONFIG REQUIRED)", "find_package(LibColorCorrect ${PROJECT_DEP_VERSION} CONFIG)"),
    ("find_package(ScreenSaverDBusInterface CONFIG REQUIRED)", "find_package(ScreenSaverDBusInterface CONFIG)\n# 6.7 relies on Qt6::DBus arriving transitively from Linux-only deps; give every target its headers.\nlink_libraries(Qt6::DBus)"),
    ("find_package(KRunnerAppDBusInterface CONFIG REQUIRED)", "find_package(KRunnerAppDBusInterface CONFIG)"),
    ("find_package(KSMServerDBusInterface CONFIG REQUIRED)", "find_package(KSMServerDBusInterface CONFIG)"),
    ("find_package(KSysGuard CONFIG REQUIRED)", "find_package(KSysGuard CONFIG)"),
    ("TYPE REQUIRED)\n    PURPOSE \"Collection of Wayland protocols", "TYPE REQUIRED)\n    PURPOSE \"Collection of Wayland protocols"),
    ("TYPE REQUIRED)\n    PURPOSE \"Required for building Tablet input KCM\"", "TYPE OPTIONAL)\n    PURPOSE \"Required for building Tablet input KCM\""),
    ("TYPE REQUIRED)\n    PURPOSE \"Required for building the X11 based workspace\"", "TYPE OPTIONAL)\n    PURPOSE \"Required for building the X11 based workspace\""),
    ("TYPE REQUIRED)\n    PURPOSE \"Support audible bell in kaccess\"", "TYPE OPTIONAL)\n    PURPOSE \"Support audible bell in kaccess\""),
    ("TYPE REQUIRED)\n    PURPOSE \"Retrieving timezone info\"", "TYPE OPTIONAL)\n    PURPOSE \"Retrieving timezone info\""),
    ("find_package(Canberra)", "find_package(Canberra)"),
    ("find_package(ICU COMPONENTS i18n uc)", "find_package(ICU COMPONENTS i18n uc)"),
]:
    text = text.replace(old, new)

text = text.replace("pkg_check_modules(XKBREGISTRY xkbregistry REQUIRED IMPORTED_TARGET)",
                    "pkg_check_modules(XKBREGISTRY xkbregistry IMPORTED_TARGET)")
text = text.replace("set_package_properties(XCB PROPERTIES TYPE REQUIRED)",
                    "set_package_properties(XCB PROPERTIES TYPE OPTIONAL)")
text = text.replace("""find_package(XCB
    REQUIRED COMPONENTS
        XCB SHM IMAGE
    OPTIONAL_COMPONENTS
        XKB XINPUT ATOM RECORD
)""", """find_package(XCB COMPONENTS XCB SHM IMAGE OPTIONAL_COMPONENTS XKB XINPUT ATOM RECORD)""")
text = text.replace("include(ConfigureChecks.cmake)", "# xios-ios-skip: include(ConfigureChecks.cmake)")
for package in ["X11", "Canberra", "ICU"]:
    text = re.sub(
        rf"(set_package_properties\({package} PROPERTIES\b.*?TYPE\s+)REQUIRED(\s*\))",
        rf"\1OPTIONAL\2",
        text,
        flags=re.S,
    )

keep = {
    "applets",
    "containments",
    "imports",
    "imports/activitymanager/",
    "layout-templates",
    "runners",
    "toolboxes",
    # Previously skipped wholesale (System Settings had almost no pages).
    # Now kept; kcms/CMakeLists.txt is rewritten below to a working subset.
    "kcms",
}

def subdir_repl(match: re.Match[str]) -> str:
    name = match.group(1)
    if name in keep:
        return match.group(0)
    return f"# xios-ios-skip: {match.group(0)}"

text = re.sub(r"^add_subdirectory\(([^)]+)\)", subdir_repl, text, flags=re.M)
text = re.sub(r"^ki18n_install\(po\)", "# xios-ios-skip: ki18n_install(po)", text, flags=re.M)
text = re.sub(r"^kdoctools_install\(po\)", "# xios-ios-skip: kdoctools_install(po)", text, flags=re.M)
text = text.replace("set(INSTALL_SDDM_THEME TRUE)", "set(INSTALL_SDDM_THEME FALSE)")

path.write_text(text)
PY

python3 - "$src/applets/CMakeLists.txt" <<'PY'
import re
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(r"^[ \t]*# xios-ios-skip: add_subdirectory\(pager\)", "add_subdirectory(pager)", text, flags=re.M)
for name in ["trash", "showActivityManager", "kimpanel"]:
    text = re.sub(rf"^[ \t]*add_subdirectory\({re.escape(name)}\)", f"# xios-ios-skip: add_subdirectory({name})", text, flags=re.M)
text = text.replace("plasma_install_package(activitypager org.kde.plasma.activitypager)",
                    "# xios-ios-skip: plasma_install_package(activitypager org.kde.plasma.activitypager)")
text = text.replace("plasma_install_package(keyboardlayout org.kde.plasma.keyboardlayout)",
                    "# xios-ios-skip: plasma_install_package(keyboardlayout org.kde.plasma.keyboardlayout)")
path.write_text(text)
PY

python3 - "$src/layout-templates/org.kde.plasma.desktop.defaultPanel/contents/layout.js" <<'PY'
import re
import sys
from xios_fixlib import Path, todo

panel = Path(sys.argv[1])
text = panel.read_text()
text, count = re.subn(
    r"^panel\.height\s*=.*$",
    "panel.height = Math.max(48, 2 * Math.floor(gridUnit * 2.5 / 2))",
    text,
    count=1,
    flags=re.M,
)
if count != 1:
    todo("default panel height assignment not found")
text = re.sub(r'^.*panel\.addWidget\("org\.kde\.plasma\.pager"\).*$',
              'panel.addWidget("org.kde.plasma.pager")', text, flags=re.M)
text = re.sub(r'^.*panel\.addWidget\("org\.kde\.plasma\.systemtray"\).*$',
              'panel.addWidget("org.kde.plasma.systemtray")', text, flags=re.M)
kicker_block = """var kicker = panel.addWidget("org.kde.plasma.kicker")
kicker.currentConfigGroup = ["General"]
kicker.writeConfig("favoriteApps", "org.kde.kwrite.desktop,org.kde.gwenview.desktop,org.kde.ark.desktop")
kicker.writeConfig("favoritesPortedToKAstats", false)"""
if kicker_block not in text:
    if 'panel.addWidget("org.kde.plasma.kickoff")' in text:
        text = text.replace('panel.addWidget("org.kde.plasma.kickoff")', kicker_block)
    elif 'panel.addWidget("org.kde.plasma.kicker")' in text:
        text = text.replace('panel.addWidget("org.kde.plasma.kicker")', kicker_block)
    else:
        todo("default panel launcher widget not found")
panel.write_text(text)
PY

python3 - "$src/applets/taskmanager/CMakeLists.txt" "$src/applets/taskmanager/plugin/backend.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

cmake = Path(sys.argv[1])
backend = Path(sys.argv[2])
header = backend.with_name("backend.h")

text = cmake.read_text()
text = text.replace(
    "                      KSysGuard::ProcessCore\n",
    "                      $<$<TARGET_EXISTS:KSysGuard::ProcessCore>:KSysGuard::ProcessCore>\n",
)
if "OUTPUT_NAME plasma_private_taskmanagerplugin" not in text:
    text = text.replace(
        "add_library(taskmanagerplugin SHARED ${taskmanagerplugin_SRCS})\n",
        "add_library(taskmanagerplugin SHARED ${taskmanagerplugin_SRCS})\n"
        "set_target_properties(taskmanagerplugin PROPERTIES OUTPUT_NAME plasma_private_taskmanagerplugin)\n",
    )
cmake.write_text(text)

qmldir = header.with_name("qmldir")
text = qmldir.read_text()
text = text.replace("plugin taskmanagerplugin\n", "plugin plasma_private_taskmanagerplugin\n")
qmldir.write_text(text)

text = header.read_text()
text = text.replace("#include <netwm.h>\n", "")
header.write_text(text)

text = backend.read_text()
if "XIOS_HAVE_KSYSGUARD_PROCESSCORE" not in text:
    text = text.replace(
        "#include <processcore/process.h>\n#include <processcore/processes.h>\n",
        "#if __has_include(<processcore/process.h>) && __has_include(<processcore/processes.h>)\n"
        "#define XIOS_HAVE_KSYSGUARD_PROCESSCORE 1\n"
        "#include <processcore/process.h>\n"
        "#include <processcore/processes.h>\n"
        "#else\n"
        "#define XIOS_HAVE_KSYSGUARD_PROCESSCORE 0\n"
        "#endif\n",
    )
old = """qint64 Backend::parentPid(qint64 pid) const
{
    KSysGuard::Processes procs;
    procs.updateOrAddProcess(pid);

    KSysGuard::Process *proc = procs.getProcess(pid);
    if (!proc) {
        return -1;
    }

    int parentPid = proc->parentPid();
    if (parentPid != -1) {
        procs.updateOrAddProcess(parentPid);

        KSysGuard::Process *parentProc = procs.getProcess(parentPid);
        if (!parentProc) {
            return -1;
        }

        if (!proc->cGroup().isEmpty() && parentProc->cGroup() == proc->cGroup()) {
            return parentProc->pid();
        }
    }

    return -1;
}
"""
new = """qint64 Backend::parentPid(qint64 pid) const
{
#if XIOS_HAVE_KSYSGUARD_PROCESSCORE
    KSysGuard::Processes procs;
    procs.updateOrAddProcess(pid);

    KSysGuard::Process *proc = procs.getProcess(pid);
    if (!proc) {
        return -1;
    }

    int parentPid = proc->parentPid();
    if (parentPid != -1) {
        procs.updateOrAddProcess(parentPid);

        KSysGuard::Process *parentProc = procs.getProcess(parentPid);
        if (!parentProc) {
            return -1;
        }

        if (!proc->cGroup().isEmpty() && parentProc->cGroup() == proc->cGroup()) {
            return parentProc->pid();
        }
    }
#else
    Q_UNUSED(pid);
#endif

    return -1;
}
"""
if old not in text and "XIOS_HAVE_KSYSGUARD_PROCESSCORE" not in text:
    todo("taskmanager parentPid block not found")
if old in text:
    text = text.replace(old, new)
backend.write_text(text)
PY

python3 - "$src/applets/pager/pagermodel.cpp" "$src/applets/pager/windowmodel.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

pagermodel = Path(sys.argv[1])
windowmodel = Path(sys.argv[2])

text = pagermodel.read_text()
text = text.replace("#include <xwindowtasksmodel.h>\n", "#if HAVE_X11\n#include <xwindowtasksmodel.h>\n#endif\n")
old = """    if (KWindowSystem::isPlatformX11()) {
        indices = findWindows(TaskManager::XWindowTasksModel::winIdsFromMimeData(mimeData, &ok));
    } else if (KWindowSystem::isPlatformWayland()) {
        indices = findWindows(TaskManager::WaylandTasksModel::winIdsFromMimeData(mimeData, &ok));
    }
"""
new = """#if HAVE_X11
    if (KWindowSystem::isPlatformX11()) {
        indices = findWindows(TaskManager::XWindowTasksModel::winIdsFromMimeData(mimeData, &ok));
    } else
#endif
    if (KWindowSystem::isPlatformWayland()) {
        indices = findWindows(TaskManager::WaylandTasksModel::winIdsFromMimeData(mimeData, &ok));
    }
"""
if old in text:
    text = text.replace(old, new)
elif "XWindowTasksModel::winIdsFromMimeData" in text and "#if HAVE_X11\n    if (KWindowSystem::isPlatformX11())" not in text:
    todo("pager drop X11 branch not found")
pagermodel.write_text(text)

text = windowmodel.read_text()
text = text.replace("#include <KX11Extras>\n", "#if HAVE_X11\n#include <KX11Extras>\n#endif\n")
old = """        if (KWindowSystem::isPlatformX11() && KX11Extras::mapViewport()) {
            int x = windowGeo.center().x() % clampingRect.width();
            int y = windowGeo.center().y() % clampingRect.height();

            if (x < 0) {
                x = x + clampingRect.width();
            }

            if (y < 0) {
                y = y + clampingRect.height();
            }

            const QRect mappedGeo(x - windowGeo.width() / 2, y - windowGeo.height() / 2, windowGeo.width(), windowGeo.height());

            if (filterByScreen() && screenGeometry().isValid()) {
                const QPoint &screenOffset = screenGeometry().topLeft();

                windowGeo = mappedGeo.translated(0 - screenOffset.x(), 0 - screenOffset.y());
            }
        } else if (filterByScreen() && screenGeometry().isValid()) {
"""
new = """#if HAVE_X11
        if (KWindowSystem::isPlatformX11() && KX11Extras::mapViewport()) {
            int x = windowGeo.center().x() % clampingRect.width();
            int y = windowGeo.center().y() % clampingRect.height();

            if (x < 0) {
                x = x + clampingRect.width();
            }

            if (y < 0) {
                y = y + clampingRect.height();
            }

            const QRect mappedGeo(x - windowGeo.width() / 2, y - windowGeo.height() / 2, windowGeo.width(), windowGeo.height());

            if (filterByScreen() && screenGeometry().isValid()) {
                const QPoint &screenOffset = screenGeometry().topLeft();

                windowGeo = mappedGeo.translated(0 - screenOffset.x(), 0 - screenOffset.y());
            }
        } else
#endif
        if (filterByScreen() && screenGeometry().isValid()) {
"""
if old in text:
    text = text.replace(old, new)
elif "KX11Extras::mapViewport()" in text and "#if HAVE_X11\n        if (KWindowSystem::isPlatformX11()" not in text:
    todo("pager X11 viewport branch not found")
windowmodel.write_text(text)
PY

python3 - "$src/applets/window-list/contents/ui/main.qml" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
for name in (
    "RightPosedTopAlignedPopup",
    "BottomPosedLeftAlignedPopup",
    "LeftPosedTopAlignedPopup",
    "TopPosedLeftAlignedPopup",
):
    text = text.replace(f"PlasmaCore.Types.{name}", f"PlasmaExtras.Menu.{name}")
path.write_text(text)
PY

python3 - "$src/applets/kicker/main.qml" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    """    onSystemFavoritesChanged: {
        systemFavorites.favorites = Plasmoid.configuration.favoriteSystemActions;
    }
""",
    """    onSystemFavoritesChanged: {
        if (systemFavorites) {
            systemFavorites.favorites = Plasmoid.configuration.favoriteSystemActions;
        }
    }
""",
)
text = text.replace(
    """        function onFavoritesChanged() {
            Plasmoid.configuration.favoriteSystemActions = target.favorites;
        }
""",
    """        function onFavoritesChanged() {
            if (target) {
                Plasmoid.configuration.favoriteSystemActions = target.favorites;
            }
        }
""",
)
text = text.replace(
    """        function onFavoriteSystemActionsChanged() {
            systemFavorites.favorites = Plasmoid.configuration.favoriteSystemActions;
        }
""",
    """        function onFavoriteSystemActionsChanged() {
            if (systemFavorites) {
                systemFavorites.favorites = Plasmoid.configuration.favoriteSystemActions;
            }
        }
""",
)
path.write_text(text)
PY

python3 - "$src/applets/kicker/RunnerResultsList.qml" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("verticalAlignment: Text.AlignVTop", "verticalAlignment: Text.AlignTop")
path.write_text(text)
PY

python3 - "$src" <<'PY'
import re
import sys
from xios_fixlib import Path, todo

src = Path(sys.argv[1])
favorite_apps = "org.kde.kwrite.desktop,org.kde.gwenview.desktop,org.kde.ark.desktop"
system_applications = "systemsettings.desktop"

def replace_default(path: Path, entry: str, value: str) -> None:
    text = path.read_text()
    pattern = rf'(<entry\s+name="{re.escape(entry)}"[^>]*>.*?<default>)(.*?)(</default>)'
    text, count = re.subn(pattern, lambda match: f"{match.group(1)}{value}{match.group(3)}", text, count=1, flags=re.S)
    if count != 1:
        todo(f"{entry} default not found: {path}")
    path.write_text(text)

kicker = src / "applets/kicker/main.xml"
kickoff = src / "applets/kickoff/main.xml"
for path in (kicker, kickoff):
    if not path.exists():
        todo(f"launcher config not found: {path}")
replace_default(kicker, "favoriteApps", favorite_apps)
replace_default(kickoff, "favorites", favorite_apps)
replace_default(kickoff, "systemApplications", system_applications)
PY

python3 - "$src/containments/desktop/CMakeLists.txt" <<'PY'
import re
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(r"^[ \t]*add_subdirectory\(plugins\)", "add_subdirectory(plugins)", text, flags=re.M)
path.write_text(text)
PY

python3 - "$src/containments/desktop/plugins/CMakeLists.txt" <<'PY'
import re
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(r"^[ \t]*add_subdirectory\(folder\)", "add_subdirectory(folder)", text, flags=re.M)
path.write_text(text)
PY

python3 - "$src/containments/desktop/package/contents/ui/main.qml" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
old = """        Layout.minimumWidth: preferredWidth(!isPopup)
        Layout.minimumHeight: preferredHeight(!isPopup)

        Layout.preferredWidth: preferredWidth(false)
        Layout.preferredHeight: preferredHeight(false)
"""
new = """        // On iOS/QtWayland the desktop containment is anchored to the screen,
        // not managed by a Qt Quick Layout. Omit the attached layout hints
        // here; on iOS they feed a startup binding loop in QQuickLayoutAttached
        // before the real folder containment can finish loading.
"""
if old not in text:
    # Plasma 6.7 sets the Layout bindings from Qt.callLater itself, which is what this hunk emulated.
    if "not managed by a Qt Quick Layout. Omit the attached layout hints" not in text and "Layout bindings need to be set delayed" not in text:
        todo("desktop containment layout block not found")
else:
    text = text.replace(old, new)
path.write_text(text)
PY

python3 - "$src/imports/activitymanager/switcherbackend.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
if not path.exists():
    todo(0)
text = path.read_text()
text = text.replace("#include <KWindowInfo>\n", "#if HAVE_X11\n#include <KWindowInfo>\n#endif\n")
text = text.replace("#include <KX11Extras>\n", "#if HAVE_X11\n#include <KX11Extras>\n#endif\n")
text = text.replace("#include <xwindowtasksmodel.h>\n", "#if HAVE_X11\n#include <xwindowtasksmodel.h>\n#endif\n")
path.write_text(text)
PY

sed -i '/^[[:space:]]*ecm_install_po_files_as_qm(/s/^/# ios-bringup-no-linguist: /' "$src/CMakeLists.txt"

# kcms/CMakeLists.txt below is a hand-picked subset. Upstream's own guards
# already drop keyboard/mouse/touchpad/baloo/gamecontroller; additionally:
#   libkwindevices, tablet, touchscreen — need org.kde.KWin.InputDevice.xml,
#     which only kwin's libinput backend generates. This stack builds kwin
#     with fakeinput + wayland only (input comes from iosc), so it ships none;
#     these KCMs can't build and would enumerate zero devices anyway.
#   access, dateandtime, landingpage, ksmserver, runners — need X11 helpers /
#     system time daemon / session manager surface this session doesn't have.
cat > "$src/kcms/CMakeLists.txt" <<'EOF'
remove_definitions(-DQT_NO_CAST_FROM_ASCII -DQT_STRICT_ITERATORS -DQT_NO_CAST_FROM_BYTEARRAY -DQT_NO_KEYWORDS)

add_subdirectory( keys )
add_subdirectory( desktoppaths )
add_subdirectory( ksplash )
add_subdirectory(kded)
add_subdirectory(spellchecking)
add_subdirectory(qtquicksettings)
add_subdirectory(workspaceoptions)
add_subdirectory(solid_actions)
add_subdirectory(recentFiles)
add_subdirectory(activities)
EOF

# ---- taskmanager 6.7: Backend::parentPid uses KSysGuard::ProcessCore (libksysguard is not ported) -----------------------
python3 - "$src/applets/taskmanager" <<'PY'
import re
import sys
from xios_fixlib import Path, todo

d = sys.argv[1]
cm = Path(f"{d}/CMakeLists.txt")
t = cm.read_text()
t = t.replace("                      KSysGuard::ProcessCore\n",
              "                      $<$<TARGET_EXISTS:KSysGuard::ProcessCore>:KSysGuard::ProcessCore>\n")
cm.write_text(t)

b = Path(f"{d}/backend.cpp")
t = b.read_text()
if "XIOS_HAVE_KSYSGUARD_PROCESSCORE" not in t:
    t = t.replace("#include <processcore/process.h>\n#include <processcore/processes.h>\n",
                  "#if __has_include(<processcore/process.h>) && __has_include(<processcore/processes.h>)\n"
                  "#define XIOS_HAVE_KSYSGUARD_PROCESSCORE 1\n"
                  "#include <processcore/process.h>\n#include <processcore/processes.h>\n"
                  "#else\n#define XIOS_HAVE_KSYSGUARD_PROCESSCORE 0\n#endif\n", 1)
    new = re.sub(r"(qint64 Backend::parentPid\(qint64 pid\) const\n\{\n)(.*?)(\n    return -1;\n\}\n)",
                 r"\1#if XIOS_HAVE_KSYSGUARD_PROCESSCORE\n\2\n#else\n    Q_UNUSED(pid)\n#endif\n\3", t, count=1, flags=re.S)
    if new == t:
        todo("taskmanager parentPid block not found (6.7 shape)")
    b.write_text(new)
PY

# ---- Plasma 6.7 X11 guards (shared helper in xios_fixlib) ------------------------------------------------------------
python3 - "$src" <<'PY'
import sys
from xios_fixlib import guard_x11_tree

print("guard_x11_tree edits:", guard_x11_tree(sys.argv[1]))
PY
