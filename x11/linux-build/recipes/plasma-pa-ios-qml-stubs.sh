#!/usr/bin/env bash
# Historically blanked org.kde.plasma.volume's contents/ui/main.qml down to a
# 1x1 Item to dodge a QQuickFlickablePrivate SIGBUS at shell startup (the real
# applet UI uses ListView/Flickable-derived views).
#
# That crash's root cause is fixed properly in
# recipes/qtdeclarative-ios-fixes.sh (the Q_OS_IOS deceleration/maxVelocity
# defaults for QQuickFlickablePrivate). With the fix in place the upstream
# volume applet UI builds and runs without the SIGBUS, so the stand-in is
# reverted: this script is now a no-op and the real upstream main.qml ships
# unmodified. Kept (rather than deleted) so plasma-pa.mk's call site does not
# need editing and so this history is visible if the Flickable fix is ever
# reverted.
set -euo pipefail

root=${1:?usage: plasma-pa-ios-qml-stubs.sh <package-root>}
