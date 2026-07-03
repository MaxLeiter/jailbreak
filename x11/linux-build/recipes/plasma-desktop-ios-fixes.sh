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
    "layout-templates",
    "runners",
    "containments",
    "toolboxes",
    "applets",
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

python3 - "$src/containments/desktop/CMakeLists.txt" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(r"^[ \t]*add_subdirectory\(plugins\)", "# ios-firstlight-skip: add_subdirectory(plugins)", text, flags=re.M)
path.write_text(text)
PY

python3 - "$src/imports/activitymanager/switcherbackend.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    raise SystemExit(0)
text = path.read_text()
text = text.replace("#include <KX11Extras>\n", "#if HAVE_X11\n#include <KX11Extras>\n#endif\n")
path.write_text(text)
PY

sed -i '/^[[:space:]]*ecm_install_po_files_as_qm(/s/^/# ios-bringup-no-linguist: /' "$src/CMakeLists.txt"
