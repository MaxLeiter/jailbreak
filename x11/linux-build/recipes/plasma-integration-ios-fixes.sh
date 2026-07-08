#!/usr/bin/env bash
# plasma-integration-ios-fixes.sh - trim Linux/X11-only theme hooks for iOS.
set -euo pipefail

src=${1:?usage: plasma-integration-ios-fixes.sh <plasma-integration-source-dir>}

sed -i '/^[[:space:]]*kde_configure_git_pre_commit_hook(/s/^/# ios-style-no-git-hook: /' "$src/CMakeLists.txt"

python3 - "$src/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace('TYPE REQUIRED\n    PURPOSE "Required to pass style properties to native Windows on X11 Platform"',
                    'TYPE OPTIONAL\n    PURPOSE "Required to pass style properties to native Windows on X11 Platform"')
path.write_text(text)
PY

python3 - "$src/qt6/src/platformtheme/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("                        TYPE REQUIRED\n", "                        TYPE OPTIONAL\n")
text = text.replace("    x11integration.cpp x11integration.h\n", "")
text = text.replace("        XCB::XCB\n", "")
insert = """if(HAVE_X11)
  target_sources(KDEPlasmaPlatformTheme6 PRIVATE x11integration.cpp x11integration.h)
endif()

"""
needle = "target_sources(KDEPlasmaPlatformTheme6 PRIVATE ${platformtheme_SRCS})\n\n"
if insert not in text:
    text = text.replace(needle, needle + insert)
path.write_text(text)
PY

python3 - "$src/qt6/src/platformtheme/kdeplatformtheme.h" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#include <private/qgenericunixthemes_p.h>\n",
                    "#include <config-platformtheme.h>\n#include <qpa/qplatformtheme.h>\n")
text = text.replace("class X11Integration;\n", "#if HAVE_X11\nclass X11Integration;\n#endif\n")
text = text.replace("class KdePlatformTheme : public QGenericUnixTheme",
                    "class KdePlatformTheme : public QPlatformTheme")
text = text.replace("    QScopedPointer<X11Integration> m_x11Integration;\n",
                    "#if HAVE_X11\n    QScopedPointer<X11Integration> m_x11Integration;\n#endif\n")
path.write_text(text)
PY

python3 - "$src/qt6/src/platformtheme/kdeplatformtheme.cpp" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace('#include "x11integration.h"\n',
                    '#if HAVE_X11\n#include "x11integration.h"\n#endif\n')
text = text.replace("""    if (m_x11Integration) {
        m_x11Integration->setWindowProperty(window, s_x11AppMenuServiceNamePropertyName, serviceName.toUtf8());
        m_x11Integration->setWindowProperty(window, s_x11AppMenuObjectPathPropertyName, objectPath.toUtf8());
    }

""", """#if HAVE_X11
    if (m_x11Integration) {
        m_x11Integration->setWindowProperty(window, s_x11AppMenuServiceNamePropertyName, serviceName.toUtf8());
        m_x11Integration->setWindowProperty(window, s_x11AppMenuObjectPathPropertyName, objectPath.toUtf8());
    }
#endif

""")
text = re.sub(
    r"QPlatformMenuBar \*KdePlatformTheme::createPlatformMenuBar\(\) const\n\{.*?\n\}\n\n// Force QtQuickControls",
    """QPlatformMenuBar *KdePlatformTheme::createPlatformMenuBar() const
{
    // iosc/Wayland has no global menu-bar convention (no top-level menu bar
    // surface like macOS or a DBusMenu host like Plasma X11); returning
    // nullptr keeps Qt Widgets apps rendering their menus in-window instead.
    return nullptr;
}

// Force QtQuickControls""",
    text,
    flags=re.S,
)
path.write_text(text)
PY
