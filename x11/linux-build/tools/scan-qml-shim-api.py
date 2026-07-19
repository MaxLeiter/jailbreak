#!/usr/bin/env python3
"""Scan QML sources for properties expected by first-light shim components.

This is intentionally static and conservative. It catches the cheap class of
Plasma bring-up failures where a real QML file instantiates one of our stubbed
components and assigns a property that the stub does not expose.
"""

from __future__ import annotations

import argparse
import re
import tarfile
import tempfile
from pathlib import Path


STUBBED_COMPONENTS = {
    "QuickSettings",
    "WallpaperSelector",
    "QuickSettingsPanel",
    "StatusBar",
    "AudioApplet",
    "VolumeOSD",
}
# Pruned 2026-07-08: ActionDrawer, ActionDrawerOpenSurface,
# PortraitContentContainer, LandscapeContentContainer, KRunnerScreen,
# KRunnerWidget, MediaControlsWidget, NotificationsWidget, PasswordBar and
# AppletListViewer were removed - each was already reverted to upstream QML
# (recipes/plasma-mobile-ios-qml-stubs.sh's restore_upstream_file calls for
# PasswordBar/AppletListViewer/folio+halcyon main.qml; the others are gone
# from that script entirely) so they no longer correspond to any generated
# compatibility provider. The obsolete no-op libplasma and plasma-pa stub
# installers were deleted after their QtQuick fixes moved into the real source
# patches, so there is nothing to scan for those packages.

VIEW_COMPONENTS = {"GridView", "ListView", "Flickable"}

QTQUICK_PROPS = {
    "id",
    "anchors",
    "width",
    "height",
    "implicitWidth",
    "implicitHeight",
    "x",
    "y",
    "z",
    "visible",
    "opacity",
    "enabled",
    "focus",
    "activeFocus",
    "activeFocusOnTab",
    "clip",
    "scale",
    "rotation",
    "transform",
    "states",
    "state",
    "transitions",
    "children",
    "data",
    "objectName",
    "parent",
    "resources",
    "Layout",
    "Kirigami",
    "Keys",
}

ITEM_STUB_PROPS = {
    "shell",
    "state",
    "window",
    "screen",
    "panel",
    "containment",
    "plasmoid",
    "model",
    "sourceModel",
    "currentPlayer",
    "popup",
    "homeScreen",
    "folio",
    "actionDrawer",
    "notificationModel",
    "notificationSettings",
    "notificationsWidget",
    "restrictedPermissions",
    "historyModel",
    "pendingNotificationWithAction",
    "textField",
    "view",
    "statusNotifierSource",
    "content",
    "contentChildren",
    "edge",
    "notificationModelType",
    "historyModelType",
    "columns",
    "columnCount",
    "minimizedColumns",
    "quickSettingsCount",
    "rowCount",
    "pageSize",
    "previewCharIndex",
    "animationDuration",
    "direction",
    "queryString",
    "backgroundColor",
    "pluginName",
    "pinLabel",
    "prevText",
    "colorScopeColor",
    "color",
    "headerTextColor",
    "headerTextInactiveColor",
    "active",
    "expanded",
    "shown",
    "dragging",
    "opened",
    "opening",
    "isOpen",
    "horizontal",
    "showSecondRow",
    "showDropShadow",
    "disableSystemTray",
    "actionsRequireUnlock",
    "openToPinnedMode",
    "doNotDisturbModeEnabled",
    "hasNotifications",
    "listOverflowing",
    "externalEdit",
    "isPinMode",
    "keypadOpen",
    "showChar",
    "showFullApplet",
    "suppressActiveClose",
    "isCurrent",
    "isOnLargeScreen",
    "showTime",
    "availableHeight",
    "topMargin",
    "bottomMargin",
    "leftMargin",
    "rightMargin",
    "offset",
    "oldOffset",
    "oldMouseY",
    "offsetDist",
    "offsetHeight",
    "totalOffsetDist",
    "largePortraitThreshold",
    "maximizedQuickSettingsOffset",
    "minimizedQuickSettingsOffset",
    "minimizedViewProgress",
    "fullViewProgress",
    "closedContentY",
    "oldContentY",
    "openFactor",
    "openedContentY",
    "contentHeight",
    "padding",
    "horizontalMargin",
    "intendedCellWidth",
    "maxCellWidth",
    "zoomScale",
    "columnWidth",
    "fullHeight",
    "intendedColumnWidth",
    "intendedMinimizedColumnWidth",
    "minimizedColumnWidth",
    "minimizedRowHeight",
    "rowHeight",
    "dotWidth",
    "intendedWidth",
    "minWidthHeight",
    "offsetRatio",
    "opacityValue",
    "contentImplicitHeight",
    "elementSpacing",
    "smallerTextPixelSize",
    "textPixelSize",
    "lockScreenState",
    "mode",
}

ITEM_STUB_SIGNALS = {
    "closed",
    "requestedClose",
    "requestClose",
    "drawerClosed",
    "drawerOpened",
    "permissionsRequested",
    "runPendingNotificationAction",
    "actionTriggered",
    "activated",
    "backgroundClicked",
    "unlockRequested",
    "wallpaperSettingsRequested",
}

ITEM_STUB_FUNCS = {
    "open",
    "close",
    "closeImmediately",
    "toggle",
    "expand",
    "cancelAnimations",
    "updateState",
    "startSwipe",
    "updateOffset",
    "endSwipe",
    "activateNextAction",
    "clearField",
    "requestFocus",
    "startGesture",
    "updateGestureOffset",
    "endGesture",
    "getTrackName",
    "clearHistory",
    "isRowExpanded",
    "openNotificationSettings",
    "runPendingAction",
    "setGroupExpanded",
    "toggleDoNotDisturbMode",
    "applyMinMax",
    "onRunPendingNotificationAction",
    "onOpenedChanged",
    "resetSwipeView",
    "showOverlay",
    "backspace",
    "clear",
    "enter",
    "keyPress",
    "onPasswordChanged",
    "onUnlockFailed",
    "onUnlockSucceeded",
}

VIEW_STUB_PROPS = {
    "model",
    "delegate",
    "highlight",
    "count",
    "currentIndex",
    "cellWidth",
    "cellHeight",
    "flow",
    "orientation",
    "layoutDirection",
    "verticalLayoutDirection",
    "boundsBehavior",
    "boundsMovement",
    "flickableDirection",
    "highlightRangeMode",
    "headerPositioning",
    "snapMode",
    "interactive",
    "dragging",
    "moving",
    "reuseItems",
    "keyNavigationWraps",
    "keyNavigationEnabled",
    "atYBeginning",
    "atYEnd",
    "cacheBuffer",
    "flickDeceleration",
    "pressDelay",
    "contentX",
    "contentY",
    "contentWidth",
    "contentHeight",
    "topMargin",
    "bottomMargin",
    "leftMargin",
    "rightMargin",
    "displayMarginBeginning",
    "displayMarginEnd",
    "preferredHighlightBegin",
    "preferredHighlightEnd",
    "highlightMoveDuration",
    "highlightResizeDuration",
    "maximumFlickVelocity",
    "spacing",
    "currentItem",
    "add",
    "displaced",
    "header",
    "highlightFollowsCurrentItem",
    "content",
    "topEdgeCallback",
    "bottomEdgeCallback",
    "leftEdgeCallback",
    "rightEdgeCallback",
}

VIEW_STUB_SIGNALS = {
    "movementStarted",
    "movementEnded",
    "flickStarted",
    "flickEnded",
}

VIEW_STUB_FUNCS = {
    "itemAtIndex",
    "indexAt",
    "flick",
    "positionViewAtIndex",
    "resizeContent",
    "returnToBounds",
}


def strip_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//.*", "", text)


def source_root(path: Path) -> tuple[tempfile.TemporaryDirectory[str] | None, Path]:
    if path.is_dir():
        return None, path
    tmp = tempfile.TemporaryDirectory()
    root = Path(tmp.name)
    with tarfile.open(path) as archive:
        archive.extractall(root)
    dirs = [p for p in root.iterdir() if p.is_dir()]
    return tmp, dirs[0] if len(dirs) == 1 else root


def find_blocks(text: str, component: str):
    pattern = re.compile(r"(?<![\w.])" + re.escape(component) + r"\s*\{")
    for match in pattern.finditer(text):
        start = match.end() - 1
        depth = 0
        quote = ""
        escaped = False
        for index in range(start, len(text)):
            char = text[index]
            if quote:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == quote:
                    quote = ""
                continue
            if char in "'\"`":
                quote = char
                continue
            if char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    yield text[start + 1 : index]
                    break


def top_level_assignments(block: str) -> set[str]:
    assignments: set[str] = set()
    depth = 0
    quote = ""
    escaped = False
    line = []
    lines = []
    for char in block:
        if quote:
            line.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == quote:
                quote = ""
            continue
        if char in "'\"`":
            quote = char
            line.append(char)
            continue
        if char == "{":
            depth += 1
            line.append(char)
            continue
        if char == "}":
            depth -= 1
            line.append(char)
            continue
        if char == "\n" and depth == 0:
            lines.append("".join(line))
            line = []
            continue
        line.append(char)
    if line:
        lines.append("".join(line))
    for raw in lines:
        stripped = raw.strip()
        match = re.match(r"on([A-Z][A-Za-z0-9_]*)\s*:", stripped)
        if match:
            signal = match.group(1)
            assignments.add(signal[:1].lower() + signal[1:])
            continue
        match = re.match(r"([A-Za-z_][A-Za-z0-9_]*)\s*:", stripped)
        if match and match.group(1) not in {"if", "for", "while", "switch", "case"}:
            assignments.add(match.group(1))
    return assignments


def declarations(text: str) -> tuple[set[str], set[str], set[str]]:
    props = set(
        re.findall(
            r"(?:^|\n)\s*(?:readonly\s+)?property\s+"
            r"(?:(?:default\s+)?alias|var|int|real|bool|string|url|color|Item|Component|QtObject)"
            r"\s+([A-Za-z_][A-Za-z0-9_]*)",
            text,
        )
    )
    signals = set(re.findall(r"(?:^|\n)\s*signal\s+([A-Za-z_][A-Za-z0-9_]*)", text))
    funcs = set(re.findall(r"(?:^|\n)\s*function\s+([A-Za-z_][A-Za-z0-9_]*)", text))
    return props, signals, funcs


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path, help="QML source tree or tarball")
    parser.add_argument("--all", action="store_true", help="print all component summaries")
    args = parser.parse_args()

    tmp, root = source_root(args.source)
    try:
        qml_files = list(root.rglob("*.qml"))
        texts = {path: strip_comments(path.read_text(errors="ignore")) for path in qml_files}
        had_missing = False
        for component in sorted(STUBBED_COMPONENTS | VIEW_COMPONENTS):
            provided_props = VIEW_STUB_PROPS if component in VIEW_COMPONENTS else ITEM_STUB_PROPS
            provided_signals = VIEW_STUB_SIGNALS if component in VIEW_COMPONENTS else ITEM_STUB_SIGNALS
            provided_funcs = VIEW_STUB_FUNCS if component in VIEW_COMPONENTS else ITEM_STUB_FUNCS
            assigned: set[str] = set()
            sites = []
            for path, text in texts.items():
                for block in find_blocks(text, component):
                    keys = top_level_assignments(block)
                    if keys:
                        assigned |= keys
                        sites.append((path.relative_to(root), keys))
            declared_props: set[str] = set()
            declared_signals: set[str] = set()
            declared_funcs: set[str] = set()
            for path in qml_files:
                if path.name == component + ".qml":
                    props, signals, funcs = declarations(texts[path])
                    declared_props |= props
                    declared_signals |= signals
                    declared_funcs |= funcs
            covered_changed_signals = {
                name
                for name in assigned
                if name.endswith("Changed")
                and name[:-7]
                and (name[:-7] in provided_props or name[:-7] in QTQUICK_PROPS)
            }
            missing_assigned = assigned - covered_changed_signals - provided_props - provided_signals - QTQUICK_PROPS
            missing_declared = declared_props - provided_props - QTQUICK_PROPS
            missing_signals = declared_signals - provided_signals
            missing_funcs = declared_funcs - provided_funcs
            if missing_assigned or missing_declared or missing_signals or missing_funcs:
                had_missing = True
            if args.all or missing_assigned or missing_declared or missing_signals or missing_funcs:
                print(f"## {component}")
                if assigned:
                    print("assigned:", " ".join(sorted(assigned)))
                if missing_assigned:
                    print("missing assigned:", " ".join(sorted(missing_assigned)))
                if declared_props:
                    print("upstream props:", " ".join(sorted(declared_props)))
                if missing_declared:
                    print("missing upstream props:", " ".join(sorted(missing_declared)))
                if declared_signals:
                    print("upstream signals:", " ".join(sorted(declared_signals)))
                if missing_signals:
                    print("missing upstream signals:", " ".join(sorted(missing_signals)))
                if declared_funcs:
                    print("upstream funcs:", " ".join(sorted(declared_funcs)))
                if missing_funcs:
                    print("missing upstream funcs:", " ".join(sorted(missing_funcs)))
                print()
        return 1 if had_missing else 0
    finally:
        if tmp is not None:
            tmp.cleanup()


if __name__ == "__main__":
    raise SystemExit(main())
