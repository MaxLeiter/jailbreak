#!/usr/bin/env bash
# qqc2-desktop-style-ios-fixes.sh - source fixes for QQC2DesktopStyle on Xios.
set -euo pipefail

src=${1:?usage: qqc2-desktop-style-ios-fixes.sh <qqc2-desktop-style-source-dir>}

python3 - "$src" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])
private = src / "org.kde.desktop" / "private"
context_menu = private / "TextFieldContextMenu.qml"
menu_impl = private / "TextFieldContextMenuMenu.qml"

text = context_menu.read_text()
if "xios-lazy-context-menu-controller" not in text:
    if "pragma Singleton" not in text or "QQC2.Menu" not in text:
        raise SystemExit("unexpected TextFieldContextMenu.qml shape")

    menu_impl.write_text(text.replace("pragma Singleton\n\n", "", 1))

    context_menu.write_text("""/*
    SPDX-FileCopyrightText: 2026 Max Leiter

    SPDX-License-Identifier: LGPL-2.0-or-later
*/

pragma Singleton

import QtQml

QtObject {
    id: root

    property var _menu: null

    function _ensureMenu() {
        if (_menu !== null) {
            return _menu;
        }

        const component = Qt.createComponent(Qt.resolvedUrl("TextFieldContextMenuMenu.qml"), Component.PreferSynchronous);
        if (component.status !== Component.Ready) {
            console.warn("Failed to load KDE text field context menu:", component.errorString());
            return null;
        }

        _menu = component.createObject(null);
        if (_menu === null) {
            console.warn("Failed to create KDE text field context menu:", component.errorString());
            return null;
        }
        return _menu;
    }

    function targetClick(handlerPoint, target, spellcheckHighlighterInstantiator, mousePosition) {
        const menu = _ensureMenu();
        if (menu !== null) {
            menu.targetClick(handlerPoint, target, spellcheckHighlighterInstantiator, mousePosition);
        }
    }

    function targetKeyPressed(event, target) {
        const menu = _ensureMenu();
        if (menu !== null) {
            menu.targetKeyPressed(event, target);
        }
    }

    readonly property string _xiosMarker: "xios-lazy-context-menu-controller"
}
""")
elif not menu_impl.exists():
    raise SystemExit("TextFieldContextMenu.qml is already patched but TextFieldContextMenuMenu.qml is missing")
PY
