#!/usr/bin/env bash
# Historically installed first-light libplasma QML shims for Menu, ComboBox,
# DialogButtonBox, TabBar and SwipeView in qml/org/kde/plasma/components,
# replacing them with empty Item-bodied stand-ins to dodge a
# QQuickFlickablePrivate SIGBUS at shell startup (these controls instantiate
# QQuickFlickable-derived views).
#
# That crash's root cause is fixed properly in
# recipes/qtdeclarative-ios-fixes.sh (the Q_OS_IOS deceleration/maxVelocity
# defaults for QQuickFlickablePrivate, since the Darwin/iOS Qt target has no
# UIKit QPA platform integration to source real style hints from). With the
# fix in place upstream Menu/ComboBox/DialogButtonBox/TabBar/SwipeView build
# and run without the SIGBUS, so the stand-ins are reverted: this script is
# now a no-op and the real upstream QML ships unmodified. Kept (rather than
# deleted) so libplasma.mk's call site does not need editing and so this
# history is visible if the Flickable fix is ever reverted.
set -euo pipefail

root=${1:?usage: libplasma-ios-qml-stubs.sh <package-root>}
