#!/usr/bin/env bash
# Package-time QML compatibility fixes.
set -euo pipefail

root=${1:?usage: plasma-desktop-ios-qml-fixes.sh <package-root>}
jb="$root/var/jb"
plasmoid="$jb/usr/share/plasma/plasmoids/org.kde.desktopcontainment"
qml="$plasmoid/contents/ui/main.qml"

[ -f "$qml" ] || exit 0

python3 - "$qml" <<'PY'
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
if old in text:
    path.write_text(text.replace(old, new))
elif "not managed by a Qt Quick Layout. Omit the attached layout hints" not in text and "Layout bindings need to be set delayed" not in text:
    raise SystemExit(f"desktop containment layout block not found in {path}")
PY

# The folder view defaults to desktop:/, which needs plasma-workspace's kio_desktop worker. That worker is
# compiled out on iOS (plasma-workspace-ios-fixes.sh), so every fresh desktop showed "Unknown protocol
# 'desktop'". Default to the plain Desktop folder under the session's $HOME instead (run-kde-plasma.sh runs
# plasmashell with HOME=<prefix>/var/root; FolderModel expands the leading ~). The directory ships in the
# package so the folder view finds it on first start.
python3 - "$plasmoid" <<'PY'
import sys
from pathlib import Path

plasmoid = Path(sys.argv[1])
OLD = "desktop:/"
NEW = "~/Desktop"
targets = {
    "contents/config/main.xml": "<default>desktop:/</default>",
    "contents/ui/FolderView.qml": 'Plasmoid.configuration.url === "desktop:/"',
    "contents/ui/ConfigLocation.qml": 'cfg_url === "desktop:/"',
}
for rel, needle in targets.items():
    path = plasmoid / rel
    text = path.read_text()
    if needle not in text:
        if NEW in text and OLD not in text:
            continue  # already patched
        raise SystemExit(f"desktop containment default marker not found in {path}: {needle}")
    text = text.replace(f'"{OLD}"', f'"{NEW}"').replace(f"<default>{OLD}</default>", f"<default>{NEW}</default>")
    if f'"{OLD}"' in text:
        raise SystemExit(f"unpatched {OLD} left in {path}")
    path.write_text(text)
PY
mkdir -p "$jb/var/root/Desktop"
