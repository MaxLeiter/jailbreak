#!/usr/bin/env bash
set -euo pipefail

src=${1:?usage: qtdeclarative-ios-fixes.sh <qtdeclarative-source-dir>}

python3 - "$src/src/quick/items/qquickflickable.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
old = """    , deceleration(QGuiApplicationPrivate::platformTheme()->themeHint(QPlatformTheme::FlickDeceleration).toReal())
    , wheelDeceleration(15000)
    , maxVelocity(QGuiApplicationPrivate::platformTheme()->themeHint(QPlatformTheme::FlickMaximumVelocity).toReal())
"""
new = """#if defined(Q_OS_IOS)
    // The Darwin/iOS target is not using Qt's UIKit QPA, so the platform
    // integration does not have reliable Flickable style hints. Avoid the
    // temporary QVariant path here; real Plasma folder views otherwise corrupt
    // the constructor return path while instantiating GridView/ListView.
    , deceleration(5000)
    , wheelDeceleration(15000)
    , maxVelocity(2500)
#else
    , deceleration(QGuiApplicationPrivate::platformTheme()->themeHint(QPlatformTheme::FlickDeceleration).toReal())
    , wheelDeceleration(15000)
    , maxVelocity(QGuiApplicationPrivate::platformTheme()->themeHint(QPlatformTheme::FlickMaximumVelocity).toReal())
#endif
"""
if old in text:
    path.write_text(text.replace(old, new))
elif "Darwin/iOS target is not using Qt's UIKit QPA" not in text:
    raise SystemExit("QQuickFlickablePrivate style-hint initializer block not found")
PY

# ios-perf-shortcut-hidden-window (+ios3): QTBUG-146992. A hidden transient window (a Plasma applet popup)
# reports QWindow::isActive() while its transient parent is active, so Qt Quick Controls shortcuts in a hidden
# popup still matched. Upstream's fix is in qtbase (codereview 738776, "Consider invisible windows always not
# active"), unmerged as of 2026-10; Plasma 6.7 papered over it with `enabled: dialog.visible` on every popup,
# which re-themes the whole popup tree on each open and close. Fix the matcher where it bites: a window that is
# not visible never matches a WindowShortcut. plasma-desktop +ios12 drops the QML workaround on top of this.
python3 - "$src/src/quicktemplates/qquickshortcutcontext.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
old = "        return obj && qobject_cast<QWindow*>(obj)->isActive() && !isBlockedByPopup(item);\n"
new = ("        // xios ios-perf-shortcut-hidden-window: QTBUG-146992, a hidden transient window can report isActive().\n"
       "        return obj && qobject_cast<QWindow*>(obj)->isVisible() && qobject_cast<QWindow*>(obj)->isActive()\n"
       "            && !isBlockedByPopup(item);\n")
if old in text:
    path.write_text(text.replace(old, new))
elif "ios-perf-shortcut-hidden-window" not in text:
    raise SystemExit("QQuickShortcutContext WindowShortcut return not found")
PY
