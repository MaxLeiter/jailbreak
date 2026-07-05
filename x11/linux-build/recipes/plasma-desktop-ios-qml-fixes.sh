#!/usr/bin/env bash
# plasma-desktop-ios-qml-fixes.sh — package-time QML compatibility fixes.
set -euo pipefail

root=${1:?usage: plasma-desktop-ios-qml-fixes.sh <package-root>}
qml="$root/var/jb/usr/share/plasma/plasmoids/org.kde.desktopcontainment/contents/ui/main.qml"

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
elif "not managed by a Qt Quick Layout. Omit the attached layout hints" not in text:
    raise SystemExit(f"desktop containment layout block not found in {path}")
PY
