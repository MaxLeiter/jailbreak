#!/usr/bin/env bash
# xdg-desktop-portal-kde-ios-fixes.sh — source trims for the Xios (rootless iOS)
# cross build.
#
# Audited against Plasma 6.1.5's xdg-desktop-portal-kde tarball.
#
#   1. Qt6 `Test` is an unconditional REQUIRED COMPONENT of the top-level
#      find_package. qtbase 6.6.3-4+ios1 ships no Qt6Test cmake package and no
#      libQt6Test dylib (verified against the published debs), so this fails at
#      configure time. Drop the component — exactly the cut kf6-kio and
#      kf6-kcmutils already carry (kde-kf6.md, "KIO drops unconditional Qt6Test;
#      KCMUtils drops unconditional Qt6Test").
#
#   2. add_subdirectory(autotests) reaches Qt::Test through ecm_add_test/
#      ecm_add_tests, which have no BUILD_TESTING guard of their own, so
#      -DBUILD_TESTING=OFF alone does not save us. Drop the subdir.
#
# Everything else is cross-build hygiene shared with kscreen.mk / milou.mk: no git
# hooks, no target-side linguist install.
#
# NOT touched (deliberate):
#   * src/waylandintegration.cpp's <linux/input-event-codes.h> include. That header
#     is staged into the volume sysroot by build-kwin.sh, not patched out of sources
#     anywhere in this tree (build-wayland-apps.sh / build-gtk.sh / build-xwayland.sh
#     all do the same staging). Keeping that convention here.
#   * find_package(KIOFuse) and the two ecm_find_qmlmodule calls: both resolve to
#     TYPE RUNTIME in the feature summary, so a miss is a warning, not an error.
#   * The screencast / remote-desktop / input-capture portal sources. They are pure
#     Wayland-protocol + QtDBus code with no PipeWire or libei link, so they compile;
#     whether they do anything depends on the compositor, which is a runtime matter.
set -euo pipefail

src=${1:?usage: xdg-desktop-portal-kde-ios-fixes.sh <xdg-desktop-portal-kde-source-dir>}

python3 - "$src/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

# 1. Qt6 Test component.
QT_MARKER = "# ios: qtbase is built without QtTest"
if QT_MARKER not in text:
    old = """find_package(Qt6 ${QT_MIN_VERSION} CONFIG REQUIRED COMPONENTS
    Core
    Concurrent
    DBus
    PrintSupport
    QuickWidgets
    Widgets
    WaylandClient
    Quick
    QuickControls2
    Qml
    Test
)
"""
    new = """# ios: qtbase is built without QtTest, and BUILD_TESTING is off in this cross
# build, so the Test component is dropped (same cut as KIO/KCMUtils).
find_package(Qt6 ${QT_MIN_VERSION} CONFIG REQUIRED COMPONENTS
    Core
    Concurrent
    DBus
    PrintSupport
    QuickWidgets
    Widgets
    WaylandClient
    Quick
    QuickControls2
    Qml
)
"""
    if old not in text:
        raise SystemExit("xdg-desktop-portal-kde-ios-fixes.sh: Qt6 component block not found")
    text = text.replace(old, new, 1)

# 2. autotests reach Qt::Test regardless of BUILD_TESTING.
TESTS_MARKER = "# ios: autotests link Qt::Test"
if TESTS_MARKER not in text:
    old = "add_subdirectory(autotests)\n"
    new = (
        TESTS_MARKER + " through ecm_add_test(s), which has no\n"
        "# BUILD_TESTING guard, and there is no Qt6Test package here.\n"
        "# add_subdirectory(autotests)\n"
    )
    if old not in text:
        raise SystemExit("xdg-desktop-portal-kde-ios-fixes.sh: add_subdirectory(autotests) not found")
    text = text.replace(old, new, 1)

# Cross-build hygiene.
if "# ios: source tarball build" not in text:
    text = text.replace(
        "include(KDEGitCommitHooks)",
        "# ios: source tarball build, no git hooks\n# include(KDEGitCommitHooks)",
    )
text = text.replace(
    "kde_configure_git_pre_commit_hook(CHECKS CLANG_FORMAT)",
    "# ios: no git hook in cross build",
)
text = text.replace("\nki18n_install(po)", "\n# ios-no-target-linguist: ki18n_install(po)")

path.write_text(text)
PY
