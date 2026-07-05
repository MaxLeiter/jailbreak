#!/usr/bin/env bash
# Package-time Plasma Workspace compatibility fixes.
set -euo pipefail

root=${1:?usage: plasma-workspace-ios-package-fixes.sh <package-root>}

for layout in \
  "$root/var/jb/usr/share/plasma/look-and-feel/org.kde.breeze.desktop/contents/layouts/org.kde.plasma.desktop-layout.js" \
  "$root/var/jb/usr/share/plasma/look-and-feel/org.kde.breezedark.desktop/contents/layouts/org.kde.plasma.desktop-layout.js" \
  "$root/var/jb/usr/share/plasma/look-and-feel/org.kde.breezetwilight.desktop/contents/layouts/org.kde.plasma.desktop-layout.js"; do
  [ -f "$layout" ] || continue
  python3 - "$layout" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(
    r"desktopsArray\[j\]\.wallpaperPlugin = 'org\.kde\.(?:image|color)';(?:\n    desktopsArray\[j\]\.currentConfigGroup = Array\('Wallpaper', 'org\.kde\.image', 'General'\);\n    desktopsArray\[j\]\.writeConfig\('Image', 'file:///var/jb/usr/share/backgrounds/xios/xios-default\.jpg'\);\n    desktopsArray\[j\]\.writeConfig\('PreviewImage', 'file:///var/jb/usr/share/backgrounds/xios/xios-default\.jpg'\);\n    desktopsArray\[j\]\.writeConfig\('FillMode', 2\);)?",
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
