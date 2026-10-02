#!/usr/bin/env bash
# Drops Qt6's unconditional required Test component (qtbase ships no
# Qt6Test package/dylib here, same cut kf6-kio and kf6-kcmutils take) and
# the autotests subdir (it reaches Qt::Test via ecm_add_test(s), which has
# no BUILD_TESTING guard of its own). Also strips git hooks and target-side
# linguist install for the cross build.
#
# Deliberately NOT touched:
#   * waylandintegration.cpp's <linux/input-event-codes.h> include: staged
#     into the volume sysroot by build-kwin.sh, not patched out, same as
#     elsewhere in this tree.
#   * find_package(KIOFuse) and the two ecm_find_qmlmodule calls: both
#     resolve to TYPE RUNTIME, so a miss is a warning, not a configure error.
#   * The screencast/remote-desktop/input-capture portal sources: pure
#     Wayland-protocol + QtDBus code, so they compile regardless of what
#     the compositor implements at runtime.
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

# 6.7: (a) Darwin has no pipe2(): shim it in the two files that use it; (b) the Print portal needs QPrintDialog, and
# our qtbase ships no QtPrintSupport dialogs (QT_FEATURE_printdialog is off), so the Print portal is left out.
python3 - "$src" <<'PY'
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
SHIM = """#if defined(__APPLE__) // xios: Darwin has no pipe2()
#include <fcntl.h>
#include <unistd.h>
static inline int pipe2(int fds[2], int flags)
{
    if (pipe(fds) != 0) {
        return -1;
    }
    for (int i = 0; i < 2; ++i) {
        if (flags & O_CLOEXEC) {
            fcntl(fds[i], F_SETFD, FD_CLOEXEC);
        }
        if (flags & O_NONBLOCK) {
            fcntl(fds[i], F_SETFL, fcntl(fds[i], F_GETFL) | O_NONBLOCK);
        }
    }
    return 0;
}
#endif
"""
for name in ("src/clipboard.cpp", "src/screenshotdialog.cpp"):
    p = src / name
    t = p.read_text()
    if "xios: Darwin has no pipe2()" not in t:
        # after the first #include line block start: put it before the first #include of a Qt/KDE header
        m = re.search(r"^#include ", t, flags=re.M)
        t = t[:m.start()] + SHIM + t[m.start():]
        p.write_text(t)

p = src / "src/CMakeLists.txt"
t = p.read_text()
t = re.sub(r"^    print\.(cpp|h)\n", "", t, flags=re.M)
p.write_text(t)
p = src / "src/desktopportal.cpp"
t = p.read_text()
t = t.replace('#include "print.h"\n', "").replace("    , m_print(new PrintPortal(this))\n", "")
p.write_text(t)
p = src / "src/desktopportal.h"
t = p.read_text()
t = t.replace("    PrintPortal *const m_print;\n", "")
p.write_text(t)
PY
