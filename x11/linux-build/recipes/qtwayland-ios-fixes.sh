#!/usr/bin/env bash
set -euo pipefail

src=${1:?usage: qtwayland-ios-fixes.sh <qtwayland-source-dir>}

python3 - "$src/src/plugins/shellintegration/xdg-shell/qwaylandxdgshell.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
old = """    m_popup = new Popup(this, parent, positioner);
    positioner->destroy();

    delete positioner;
}
"""
new = """    m_popup = new Popup(this, parent, positioner);

    // iOS/Xios: QtWayland registers child popups with the parent shell surface
    // before QWaylandXdgSurface::setPopup() has populated m_popup, so a
    // layer-shell parent cannot see the xdg_popup role during its first
    // attachPopup() call. Notify the parent again immediately after the role
    // exists, before the child surface commits.
    if (parent && parent->shellSurface()) {
        parent->shellSurface()->attachPopup(this);
    }

    positioner->destroy();

    delete positioner;
}
"""
if old in text:
    text = text.replace(old, new)
elif "QtWayland registers child popups with the parent shell surface" not in text:
    raise SystemExit("QWaylandXdgSurface::setPopup block not found")

old = """std::any QWaylandXdgSurface::surfaceRole() const
{
    if (m_toplevel)
        return m_toplevel->object();
    if (m_popup)
        return m_popup->object();
    return {};
}
"""
new = """std::any QWaylandXdgSurface::surfaceRole() const
{
    if (m_toplevel)
        return m_toplevel->object();
    if (m_popup) {
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
"""
if old in text:
    text = text.replace(old, new)
elif "generated protocol struct RTTI is not unified" not in text:
    raise SystemExit("QWaylandXdgSurface::surfaceRole block not found")
path.write_text(text)
PY
