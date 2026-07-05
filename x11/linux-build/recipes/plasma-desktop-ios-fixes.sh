#!/usr/bin/env bash
# plasma-desktop-ios-fixes.sh — first-light source trims for Plasma Desktop.
set -euo pipefail

src=${1:?usage: plasma-desktop-ios-fixes.sh <plasma-desktop-source-dir>}

python3 - "$src/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

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
    ("find_package(ScreenSaverDBusInterface CONFIG REQUIRED)", "find_package(ScreenSaverDBusInterface CONFIG)"),
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
text = text.replace("include(ConfigureChecks.cmake)", "# ios-firstlight-skip: include(ConfigureChecks.cmake)")
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
}

def subdir_repl(match: re.Match[str]) -> str:
    name = match.group(1)
    if name in keep:
        return match.group(0)
    return f"# ios-firstlight-skip: {match.group(0)}"

text = re.sub(r"^add_subdirectory\(([^)]+)\)", subdir_repl, text, flags=re.M)
text = re.sub(r"^ki18n_install\(po\)", "# ios-firstlight-skip: ki18n_install(po)", text, flags=re.M)
text = re.sub(r"^kdoctools_install\(po\)", "# ios-firstlight-skip: kdoctools_install(po)", text, flags=re.M)
text = text.replace("set(INSTALL_SDDM_THEME TRUE)", "set(INSTALL_SDDM_THEME FALSE)")

path.write_text(text)
PY

python3 - "$src/applets/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
for name in ["trash", "taskmanager", "pager", "showActivityManager", "kimpanel"]:
    text = re.sub(rf"^[ \t]*add_subdirectory\({re.escape(name)}\)", f"# ios-firstlight-skip: add_subdirectory({name})", text, flags=re.M)
text = text.replace("plasma_install_package(icontasks org.kde.plasma.icontasks)",
                    "# ios-firstlight-skip: plasma_install_package(icontasks org.kde.plasma.icontasks)")
text = text.replace("plasma_install_package(keyboardlayout org.kde.plasma.keyboardlayout)",
                    "# ios-firstlight-skip: plasma_install_package(keyboardlayout org.kde.plasma.keyboardlayout)")
path.write_text(text)
PY

python3 - "$src/layout-templates/org.kde.plasma.desktop.defaultPanel/contents/layout.js" <<'PY'
import sys
from pathlib import Path

panel = Path(sys.argv[1])
text = panel.read_text()
text = text.replace('panel.addWidget("org.kde.plasma.kickoff")', 'panel.addWidget("org.kde.plasma.kicker")')
text = text.replace('panel.addWidget("org.kde.plasma.pager")', '// ios-firstlight-skip: panel.addWidget("org.kde.plasma.pager")')
text = text.replace('panel.addWidget("org.kde.plasma.icontasks")', 'panel.addWidget("org.kde.plasma.windowlist")')
text = text.replace('panel.addWidget("org.kde.plasma.systemtray")', '// ios-firstlight-skip: panel.addWidget("org.kde.plasma.systemtray")')
panel.write_text(text)
PY

python3 - "$src/applets/window-list/contents/ui/main.qml" <<'PY'
import sys
from pathlib import Path

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

python3 - "$src/applets/kicker/package/contents/ui/main.qml" <<'PY'
import sys
from pathlib import Path

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

python3 - "$src/containments/desktop/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(r"^[ \t]*add_subdirectory\(plugins\)", "add_subdirectory(plugins)", text, flags=re.M)
path.write_text(text)
PY

python3 - "$src/containments/desktop/plugins/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(r"^[ \t]*add_subdirectory\(folder\)", "add_subdirectory(folder)", text, flags=re.M)
path.write_text(text)
PY

python3 - "$src/containments/desktop/package/contents/ui/main.qml" <<'PY'
import sys
from pathlib import Path

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
    if "not managed by a Qt Quick Layout. Omit the attached layout hints" not in text:
        raise SystemExit("desktop containment layout block not found")
else:
    text = text.replace(old, new)
path.write_text(text)
PY

python3 - "$src/imports/activitymanager/switcherbackend.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(0)
text = path.read_text()
text = text.replace("#include <KWindowInfo>\n", "#if HAVE_X11\n#include <KWindowInfo>\n#endif\n")
text = text.replace("#include <KX11Extras>\n", "#if HAVE_X11\n#include <KX11Extras>\n#endif\n")
text = text.replace("#include <xwindowtasksmodel.h>\n", "#if HAVE_X11\n#include <xwindowtasksmodel.h>\n#endif\n")
path.write_text(text)
PY

sed -i '/^[[:space:]]*ecm_install_po_files_as_qm(/s/^/# ios-bringup-no-linguist: /' "$src/CMakeLists.txt"
