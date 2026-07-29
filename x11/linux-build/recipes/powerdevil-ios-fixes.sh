#!/usr/bin/env bash
# powerdevil-ios-fixes.sh — PowerDevil source trims for the Xios (rootless iOS) cross build.
#
# Audited against Plasma 6.1.5's powerdevil tarball. Four independent upstream
# hard-requirements have no cmake switch, so they are cut here:
#
#   1. KF6 DocTools is a REQUIRED find_package COMPONENT of the top-level
#      find_package(KF6 ...). KF6_CMAKE_FLAGS already sets
#      CMAKE_DISABLE_FIND_PACKAGE_KF6DocTools=TRUE, which makes the component
#      NOT_FOUND and therefore fails the whole REQUIRED call. Drop the component,
#      the doc/ subdir (doc/kcm calls kdoctools_create_handbook), and
#      kdoctools_install(po).
#
#   2. find_package(UDev REQUIRED) + the vendored UdevQt client. ECM's FindUDev
#      would actually succeed against linux-build/udev-stub (it installs
#      libudev.pc/libudev.h/libudev.1.dylib into the sysroot), but that stub only
#      implements the 8 hwdb entry points gnome-bluetooth needs. UdevQt calls ~40
#      udev_device_*/udev_enumerate_*/udev_monitor_* symbols, so powerdevilcore
#      would fail to link. UdevQt's only consumer is BacklightDetector
#      (daemon/controllers/backlightbrightness.cpp -> /sys/class/backlight), which
#      is meaningless on iOS. Both are dropped; ScreenBrightnessController keeps
#      KWinDisplayDetector (a plain DBus client of KWin's brightness interface),
#      which is the correct brightness path for this stack.
#
#   3. find_package(XCB REQUIRED COMPONENTS XCB RANDR DPMS). Same X11-off policy as
#      kglobalacceld/kscreen/plasma-workspace, and libxcb-randr/libxcb-dpms are not
#      packaged. XCB is REQUIRED, so CMAKE_DISABLE_FIND_PACKAGE_XCB would hard-error
#      instead of disabling it. Dropping the call leaves XCB_FOUND false, which
#      already gates every `if (XCB_FOUND)` block and sets HAVE_XCB=0 in
#      config-powerdevil.h. The single leftover is kwinkscreenhelpereffect.cpp's
#      unconditional <private/qtx11extras_p.h> include (the rest of that file is
#      already #if HAVE_XCB-guarded), so that include gets the same guard. The class
#      itself is kept so daemon/actions/bundled/{dpms,suspendsession}.cpp compile
#      unchanged; with HAVE_XCB=0 it is a correct no-op.
#
#   4. XCB::DPMS and ${UDEV_LIBS} are referenced unconditionally in
#      daemon/CMakeLists.txt's target_link_libraries, outside the `if (XCB_FOUND)`
#      guards, so those lines have to go with the find_package calls.
#
# Plus the usual cross-build hygiene shared with kscreen/milou: no git hooks, no
# target-side linguist install, no tests.
#
# NOT touched (deliberate): the login1/ConsoleKit2 suspend path, the /sys-reading
# KAuth helpers (backlighthelper_linux.cpp, chargethresholdhelper.cpp) and the
# systemd user-unit install. All are pure QtDBus/QFile/data-file paths that compile
# fine and degrade to "unsupported" at runtime; cutting them would be a behavior
# decision, not a build fix.
set -euo pipefail

src=${1:?usage: powerdevil-ios-fixes.sh <powerdevil-source-dir>}

python3 - "$src/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()


def sub(marker, old, new, why):
    """Idempotent single replacement, keyed on a marker this script owns."""
    global text
    if marker in text:
        return
    if old not in text:
        raise SystemExit(f"powerdevil-ios-fixes.sh: {why}: pattern not found")
    text = text.replace(old, new, 1)


# 1. DocTools
sub(
    "# ios: no docbook toolchain",
    "find_package(KF6 ${KF6_MIN_VERSION} REQUIRED COMPONENTS Auth Config Crash DBusAddons DocTools I18n IdleTime ItemModels GlobalAccel KIO Kirigami2 KCMUtils Notifications Solid WindowSystem XmlGui)",
    "# ios: no docbook toolchain in the cross container, DocTools dropped.\n"
    "find_package(KF6 ${KF6_MIN_VERSION} REQUIRED COMPONENTS Auth Config Crash DBusAddons I18n IdleTime ItemModels GlobalAccel KIO Kirigami2 KCMUtils Notifications Solid WindowSystem XmlGui)",
    "KF6 REQUIRED COMPONENTS line",
)

# 2. UDev
sub(
    "# ios: the libudev stub only covers hwdb",
    "find_package(UDev REQUIRED)\n",
    "# ios: the libudev stub only covers hwdb; UdevQt needs ~40 more symbols.\n"
    "# find_package(UDev REQUIRED)\n",
    "find_package(UDev REQUIRED)",
)

# 3. XCB
sub(
    "# ios: X11 is off everywhere in this stack",
    "find_package(XCB REQUIRED COMPONENTS XCB RANDR DPMS)\n",
    "# ios: X11 is off everywhere in this stack and xcb-randr/xcb-dpms are not\n"
    "# packaged. Leaving XCB_FOUND false gates every if(XCB_FOUND) block below and\n"
    "# sets HAVE_XCB=0 in config-powerdevil.h.\n"
    "# find_package(XCB REQUIRED COMPONENTS XCB RANDR DPMS)\n"
    "set(XCB_FOUND FALSE)\n",
    "find_package(XCB REQUIRED ...)",
)

# doc/ + kdoctools
sub(
    "# ios: no DocTools, so no handbook",
    "add_subdirectory(doc)\nkdoctools_install(po)\n",
    "# ios: no DocTools, so no handbook and no kdoctools_install.\n"
    "# add_subdirectory(doc)\n# kdoctools_install(po)\n",
    "add_subdirectory(doc) block",
)

# tests
sub(
    "# ios: BUILD_TESTING is off",
    "add_subdirectory(autotests)\n",
    "# ios: BUILD_TESTING is off in the cross build.\n# add_subdirectory(autotests)\n",
    "add_subdirectory(autotests)",
)

# hygiene shared with kscreen.mk / milou.mk
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

python3 - "$src/daemon/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

MARKER = "# ios: UdevQt/backlightbrightness"

path = Path(sys.argv[1])
text = path.read_text()

if not text.startswith(MARKER):

    def drop(line, why):
        global text
        if line not in text:
            raise SystemExit(f"powerdevil-ios-fixes.sh: {why}: pattern not found")
        text = text.replace(line, "", 1)

    # UdevQt + the backlight detector it feeds.
    drop("    controllers/backlightbrightness.cpp\n", "backlightbrightness source")
    drop("    controllers/udevqtclient.cpp\n", "udevqtclient source")
    drop("    controllers/udevqtdevice.cpp\n", "udevqtdevice source")

    # Unconditional link references to the packages dropped in the top-level CMakeLists.
    drop("    XCB::DPMS\n", "XCB::DPMS link entry")
    drop("    ${UDEV_LIBS}\n", "UDEV_LIBS link entry (powerdevilcore)")
    drop("target_link_libraries(powerdevil ${UDEV_LIBS})\n", "UDEV_LIBS link entry (powerdevil)")

    text = (
        MARKER
        + " (libudev + /sys/class/backlight) and the XCB DPMS\n"
        "# link are removed by powerdevil-ios-fixes.sh; see that script for the rationale.\n"
        + text
    )
    path.write_text(text)
PY

python3 - "$src/daemon/controllers/screenbrightnesscontroller.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

if '#include "backlightbrightness.h"' in text:
    text = text.replace(
        '#include "backlightbrightness.h"\n',
        "// ios: BacklightDetector needs libudev + /sys/class/backlight; dropped.\n",
        1,
    )
if '          {new BacklightDetector(this), "internal display backlight"},\n' in text:
    text = text.replace(
        '          {new BacklightDetector(this), "internal display backlight"},\n', "", 1
    )
elif "ios: BacklightDetector needs libudev" not in text:
    raise SystemExit("powerdevil-ios-fixes.sh: BacklightDetector entry not found")

path.write_text(text)
PY

python3 - "$src/daemon/kwinkscreenhelpereffect.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

MARKER = "// ios: this Qt private X11 header"
old = "#include <private/qtx11extras_p.h>\n"
new = (
    MARKER + " does not exist in an X11-less Qt build. Every\n"
    "// other use of it in this file is already #if HAVE_XCB-guarded.\n"
    "#if HAVE_XCB\n"
    "#include <private/qtx11extras_p.h>\n"
    "#endif\n"
)
if MARKER not in text:
    if old not in text:
        raise SystemExit("powerdevil-ios-fixes.sh: qtx11extras_p.h include not found")
    text = text.replace(old, new, 1)
    path.write_text(text)
PY

# osd/osd.cpp reaches for KX11Extras, which the X11-off kf6-windowsystem build
# does not install at all. Its two call sites are both inside the non-Wayland
# else-branch of an isPlatformWayland() test, i.e. dead code on this stack, so
# guard the include and the branch body rather than stubbing the class.
python3 - "$src/osd/osd.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

MARKER = "// ios: KX11Extras is absent from the X11-off"
if MARKER not in text:
    old_inc = "#include <KX11Extras>\n"
    new_inc = (
        MARKER + " kf6-windowsystem build.\n"
        "// The only uses are in the non-Wayland branch below, which cannot run here.\n"
    )
    if old_inc not in text:
        raise SystemExit("powerdevil-ios-fixes.sh: KX11Extras include not found in osd.cpp")
    text = text.replace(old_inc, new_inc, 1)

    old_calls = (
        "        KX11Extras::setState(m_osdActionSelector->winId(), NET::SkipPager | NET::SkipSwitcher | NET::SkipTaskbar);\n"
        "        KX11Extras::setType(m_osdActionSelector->winId(), NET::OnScreenDisplay);\n"
    )
    if old_calls not in text:
        raise SystemExit("powerdevil-ios-fixes.sh: KX11Extras call sites not found in osd.cpp")
    text = text.replace(old_calls, "", 1)
    path.write_text(text)
PY

# daemon/actions/bundled/dpms.cpp has its own unguarded qtx11extras_p.h include
# (the sibling guard covers kwinkscreenhelpereffect.cpp only). Its single use is
# an isPlatformX11() test choosing an X11 fade effect; upstream's own comment
# says "On Wayland, KWin takes care of performing the effect properly", so the
# else-branch is already the correct path on this Wayland-only stack. Make the
# test compile-time false and drop the include rather than stub QX11Info.
python3 - "$src/daemon/actions/bundled/dpms.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()

MARKER = "// ios: no X11 platform here"
if MARKER not in text:
    old_inc = "#include <private/qtx11extras_p.h>\n"
    new_inc = MARKER + "; the Wayland branch below is the live one.\n"
    if old_inc not in text:
        raise SystemExit("powerdevil-ios-fixes.sh: qtx11extras_p.h include not found in dpms.cpp")
    text = text.replace(old_inc, new_inc, 1)

    old_if = "    if (QX11Info::isPlatformX11()) {"
    new_if = "    if (false) { // ios: X11 unavailable; KWin performs the fade on Wayland"
    if old_if not in text:
        raise SystemExit("powerdevil-ios-fixes.sh: isPlatformX11 test not found in dpms.cpp")
    text = text.replace(old_if, new_if, 1)
    path.write_text(text)
PY
