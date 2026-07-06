#!/usr/bin/env bash
# plasma-nano-ios-fixes.sh — source trims for first-light Plasma Nano on iOS.
set -euo pipefail

src=${1:?usage: plasma-nano-ios-fixes.sh <plasma-nano-source-dir>}

perl -0pi -e 's/#include <KX11Extras>\n/#if HAVE_X11\n#include <KX11Extras>\n#endif\n/' \
  "$src/components/fullscreenoverlay.cpp"
perl -0pi -e 's/        if \(KWindowSystem::isPlatformX11\(\)\) \{\n            KX11Extras::setState\(winId\(\), NET::SkipTaskbar \| NET::SkipPager\);\n        \} else \{\n            if \(m_plasmaShellSurface\) \{\n                m_plasmaShellSurface->setSkipTaskbar\(true\);\n                m_plasmaShellSurface->setSkipSwitcher\(true\);\n            \}\n        \}/#if HAVE_X11\n        if (KWindowSystem::isPlatformX11()) {\n            KX11Extras::setState(winId(), NET::SkipTaskbar | NET::SkipPager);\n        } else\n#endif\n        {\n            if (m_plasmaShellSurface) {\n                m_plasmaShellSurface->setSkipTaskbar(true);\n                m_plasmaShellSurface->setSkipSwitcher(true);\n            }\n        }/g' \
  "$src/components/fullscreenoverlay.cpp"

sed -i '/^[[:space:]]*ki18n_install(po)/s/^/# ios-firstlight-skip: /' "$src/CMakeLists.txt"

python3 - "$src" <<'PY'
import sys
from pathlib import Path

src = Path(sys.argv[1])

layout = src / "shell/contents/layout.js"
if layout.exists():
    layout.write_text("""// xios-firstlight-layout: skip Nano's Mycroft applets on iOS.
var desktopsArray = desktopsForActivity(currentActivity());
for (var j = 0; j < desktopsArray.length; j++) {
    var desk = desktopsArray[j];
    desk.wallpaperPlugin = "org.kde.color";
    desk.currentConfigGroup = ["Wallpaper", "org.kde.color", "General"];
    desk.writeConfig("Color", "20,20,24");
}
""")

main = src / "desktoptoolbox/contents/ui/main.qml"
if main.exists():
    text = main.read_text()
    if "xios-plasmoid-guard" not in text:
        text = text.replace(
            '    objectName: "org.kde.desktoptoolbox"\n',
            '''    objectName: "org.kde.desktoptoolbox"
    // xios-plasmoid-guard: Plasma Mobile can load Nano's toolbox without a global plasmoid object.
    function xiosPlasmoid() {
        try {
            return plasmoid
        } catch (e) {
            return null
        }
    }
    function xiosEditMode() {
        var p = xiosPlasmoid()
        return !!(p && p.containment && p.containment.corona && p.containment.corona.editMode)
    }
    function xiosAvailableScreenRect() {
        var p = xiosPlasmoid()
        return p && p.availableScreenRect ? p.availableScreenRect : Qt.rect(0, 0, main.width, main.height)
    }
    function xiosBottomMargin() {
        var r = xiosAvailableScreenRect()
        return Math.max(0, main.height - (r.y + r.height))
    }
''',
            1,
        )
        text = text.replace("opacity: plasmoid.containment.corona.editMode", "opacity: main.xiosEditMode()")
        text = text.replace(
            "bottomMargin: main.height - (plasmoid.availableScreenRect.y + plasmoid.availableScreenRect.height)",
            "bottomMargin: main.xiosBottomMargin()",
        )
        text = text.replace(
            "DesktopConfigButtons {\n        id: configButtons",
            "DesktopConfigButtons {\n        id: configButtons\n        xiosMainPlasmoid: main.xiosPlasmoid()",
            1,
        )
        main.write_text(text)

buttons = src / "desktoptoolbox/contents/ui/DesktopConfigButtons.qml"
if buttons.exists():
    text = buttons.read_text()
    if "xios-plasmoid-guard" not in text:
        text = text.replace(
            '    imagePath: "widgets/background"\n',
            '''    imagePath: "widgets/background"
    // xios-plasmoid-guard: keep the toolbox importable when no global plasmoid object exists.
    property var xiosMainPlasmoid: null
    function xiosPlasmoid() {
        if (xiosMainPlasmoid) {
            return xiosMainPlasmoid
        }
        try {
            return plasmoid
        } catch (e) {
            return null
        }
    }
    function xiosEditMode() {
        var p = xiosPlasmoid()
        return !!(p && p.corona && p.corona.editMode)
    }
    function xiosTriggerAction(name) {
        var p = xiosPlasmoid()
        if (!p || !p.internalAction) {
            return
        }
        var action = p.internalAction(name)
        if (action) {
            action.trigger()
        }
        if (p.corona) {
            p.corona.editMode = false
        }
    }
''',
            1,
        )
        text = text.replace("opacity: plasmoid.corona.editMode", "opacity: root.xiosEditMode()")
        text = text.replace("y: plasmoid.corona.editMode ? 0 : root.height", "y: root.xiosEditMode() ? 0 : root.height")
        text = text.replace('plasmoid.internalAction("add widgets").trigger();\n                plasmoid.corona.editMode = false;', 'root.xiosTriggerAction("add widgets")')
        text = text.replace('plasmoid.internalAction("configure").trigger();\n                plasmoid.corona.editMode = false;', 'root.xiosTriggerAction("configure")')
        buttons.write_text(text)
PY
