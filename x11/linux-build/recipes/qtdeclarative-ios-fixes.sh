#!/usr/bin/env bash
# qtdeclarative-ios-fixes.sh — QtQuick runtime fixes for the Darwin/iOS target.
set -euo pipefail

src=${1:?usage: qtdeclarative-ios-fixes.sh <qtdeclarative-source-dir>}

python3 - "$src/src/quick/items/qquickflickable.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
old = """    , deceleration(QGuiApplicationPrivate::platformIntegration()->styleHint(QPlatformIntegration::FlickDeceleration).toReal())
    , wheelDeceleration(15000)
    , maxVelocity(QGuiApplicationPrivate::platformIntegration()->styleHint(QPlatformIntegration::FlickMaximumVelocity).toReal())
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
    , deceleration(QGuiApplicationPrivate::platformIntegration()->styleHint(QPlatformIntegration::FlickDeceleration).toReal())
    , wheelDeceleration(15000)
    , maxVelocity(QGuiApplicationPrivate::platformIntegration()->styleHint(QPlatformIntegration::FlickMaximumVelocity).toReal())
#endif
"""
if old in text:
    path.write_text(text.replace(old, new))
elif "Darwin/iOS target is not using Qt's UIKit QPA" not in text:
    raise SystemExit("QQuickFlickablePrivate style-hint initializer block not found")
PY
