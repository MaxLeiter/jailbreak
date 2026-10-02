#!/usr/bin/env bash
# Qt 6.10 moved the Wayland client QPA into qtbase (src/plugins/platforms/wayland). This is the old
# qtwayland-ios-fixes.sh + the qwaylandintegration.cpp seds from qtwayland.mk, re-homed. Every hunk is
# a HARD failure when its anchor is missing: a silently skipped hunk is how a port rots.
set -euo pipefail

src=${1:?usage: qtbase-wayland-ios-fixes.sh <qtbase-source-dir>}
wl="$src/src/plugins/platforms/wayland"

python3 - "$wl/plugins/shellintegration/xdg-shell/qwaylandxdgshell.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

def swap(text, old, new, done_marker, what):
    if done_marker in text:
        return text
    if old not in text:
        raise SystemExit(f"{what}: anchor not found")
    return text.replace(old, new, 1)

# 6.10 builds the popup from a std::unique_ptr<Positioner> (destroyed at scope exit), unlike 6.6 which
# hand-deleted a raw pointer.
text = swap(text,
"""    m_popup = new Popup(this, parent, positioner.get());
}
""",
"""    m_popup = new Popup(this, parent, positioner.get());

    // iOS/Xios: QtWayland registers child popups with the parent shell surface
    // before QWaylandXdgSurface::setPopup() has populated m_popup, so a
    // layer-shell parent cannot see the xdg_popup role during its first
    // attachPopup() call. Notify the parent again immediately after the role
    // exists, before the child surface commits.
    if (parent && parent->shellSurface()) {
        parent->shellSurface()->attachPopup(this);
    }
}
""",
"QtWayland registers child popups with the parent shell surface",
"QWaylandXdgSurface::setPopup")

text = swap(text,
"""    if (m_popup)
        return m_popup->object();
    return {};
}
""",
"""    if (m_popup) {
        // iOS/Xios: layer-shell-qt lives in a separate dylib from QtWayland's
        // xdg-shell plugin. std::any_cast<xdg_popup *> can fail across that
        // boundary even when type().name() reports P9xdg_popup, because the
        // generated protocol struct RTTI is not unified. Use a builtin pointer
        // type for the popup role so layer-shell can recover it without relying
        // on generated-protocol RTTI.
        return static_cast<void *>(m_popup->object());
    }
    return {};
}
""",
"generated protocol struct RTTI is not unified",
"QWaylandXdgSurface::surfaceRole")
path.write_text(text)
PY

# qgenericunixtheme_p.h (6.10 name; 6.6 had 'themes') never built in our qtbase (gated UNIX AND NOT MACOS, MACOS stays set under the masquerade),
# so its private header is not staged: drop only the theme hookup (Plasma gets real theming from
# plasma-integration's own platformtheme plugin).
f="$wl/qwaylandintegration.cpp"
for needle in '#include <QtGui/private/qgenericunixtheme_p.h>' \
              'return QGenericUnixTheme::themeNames();' \
              'return QGenericUnixTheme::createUnixTheme(name);'; do
  grep -qF "$needle" "$f" || { echo "qwaylandintegration.cpp: anchor not found: $needle" >&2; exit 1; }
done
sed -i '/#include <QtGui\/private\/qgenericunixtheme_p.h>/d' "$f"
sed -i 's/return QGenericUnixTheme::themeNames();/return QStringList();/' "$f"
sed -i 's/return QGenericUnixTheme::createUnixTheme(name);/return nullptr;/' "$f"
