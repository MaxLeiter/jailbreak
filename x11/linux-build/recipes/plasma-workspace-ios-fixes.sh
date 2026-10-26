#!/usr/bin/env bash
set -euo pipefail
# xios_fixlib.Path: hunks on files Plasma 6.7 removed become logged no-ops instead of aborting.
export PYTHONPATH="$(cd "$(dirname "$0")" && pwd)${PYTHONPATH:+:$PYTHONPATH}"

src=${1:?usage: plasma-workspace-ios-fixes.sh <plasma-workspace-source-dir>}

# plasma-workspace-setup re-runs this on the same tree when a failed build is
# retried, and most edits below are not safe to apply twice (some rewrite their
# own anchors, others duplicate code blocks). Stamp the tree with this script's
# hash once every edit has landed: a re-run of the same script is a no-op, and a
# tree fixed by an older version is refused instead of being edited again.
stamp="$src/.xios-ios-fixes.sha256"
self_sha=$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')
if [ -f "$stamp" ]; then
  if [ "$(cat "$stamp")" = "$self_sha" ]; then
    echo "plasma-workspace-ios-fixes: already applied to $src"
    exit 0
  fi
  echo "plasma-workspace-ios-fixes: $src was fixed by a different version of this script;" >&2
  echo "  delete it so EXTRACT_TAR re-extracts a clean tree" >&2
  exit 1
fi

cat > "$src/shell/config-X11.h" <<'EOF'
#pragma once
#define HAVE_X11 0
EOF

python3 - "$src/CMakeLists.txt" <<'PY'
import re
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()

text = text.replace("CoreAddons KIO Prison Package\n                    GuiAddons Archive ItemModels IconThemes UnitConversion TextEditor StatusNotifierItem",
                    "CoreAddons KIO Package Solid\n                    GuiAddons Archive ItemModels IconThemes UnitConversion StatusNotifierItem")
for old, new in [
    ("find_package(Plasma5Support ${PROJECT_DEP_VERSION} REQUIRED)", "find_package(Plasma5Support ${PROJECT_DEP_VERSION})"),
    ("find_package(KSysGuard CONFIG REQUIRED)", "find_package(KSysGuard CONFIG)"),
    ("pkg_check_modules(QALCULATE libqalculate>2.0 REQUIRED IMPORTED_TARGET)", "pkg_check_modules(QALCULATE libqalculate>2.0 IMPORTED_TARGET)"),
    ("find_package(KF6Screen CONFIG REQUIRED)", "find_package(KF6Screen CONFIG)"),
    ("find_package(KScreenLocker 5.13.80 REQUIRED)", "find_package(KScreenLocker 5.13.80)"),
    ("find_package(ScreenSaverDBusInterface CONFIG REQUIRED)",
     "find_package(ScreenSaverDBusInterface CONFIG)\n"
     "if(NOT SCREENSAVER_DBUS_INTERFACE)\n"
     "    # xios fallback ScreenSaver DBus interface until kscreenlocker is ported (file written below).\n"
     "    set(SCREENSAVER_DBUS_INTERFACE \"${CMAKE_CURRENT_SOURCE_DIR}/iosc-dbus-interfaces/kf6_org.freedesktop.ScreenSaver.xml\")\n"
     "endif()\n"
     "# 6.7 relies on Qt6::DBus arriving transitively from Linux-only deps; give every target its headers.\n"
     "link_libraries(Qt6::DBus)"),
    ("find_package(Phonon4Qt6 4.6.60 REQUIRED NO_MODULE)", "find_package(Phonon4Qt6 4.6.60 NO_MODULE)"),
    ("TYPE REQUIRED)", "TYPE OPTIONAL)"),
    ("find_package(UDev REQUIRED)", "find_package(UDev)"),
]:
    text = text.replace(old, new)

# 6.7 writes the REQUIRED marker as its own line before ")": KSysGuard (guarded by KSysGuard_FOUND) and UDev.
text = re.sub(r"TYPE REQUIRED(\n\))", r"TYPE OPTIONAL\1", text)
text = text.replace('PROPERTIES DESCRIPTION "Unicode and Globalization support for software applications"\n        TYPE REQUIRED',
                    'PROPERTIES DESCRIPTION "Unicode and Globalization support for software applications"\n        TYPE OPTIONAL')

keep = {
    "applets",
    "dataengines",
    "kcms",
    "startkde",
    "lookandfeel",
    "logout-greeter",
    "libnotificationmanager",
    "libkworkspace",
    "libklookandfeel",
    "libclock",
    "libdbusmenuqt",
    "libkmpris",
    "libtaskmanager",
    "klipper",
    "menu",
    "components",
    "plasma-windowed",
    "runners",
    "shell",
    "statusnotifierwatcher",
    "themes",
    "wallpapers",
    "kioworkers",
}

def repl(match: re.Match[str]) -> str:
    name = match.group(1)
    if name in keep or name in {"doc"}:
        return match.group(0)
    return f"# ios-firstlight-skip: {match.group(0)}"

text = re.sub(r"^add_subdirectory\(([^)]+)\)", repl, text, flags=re.M)
text = re.sub(r"^ecm_optional_add_subdirectory\(([^)]+)\)",
              lambda m: f"# ios-firstlight-skip: {m.group(0)}", text, flags=re.M)
text = re.sub(r"^ki18n_install\(po\)", "# xios-ios-skip: ki18n_install(po)", text, flags=re.M)
text = re.sub(r"^kdoctools_install\(po\)", "# xios-ios-skip: kdoctools_install(po)", text, flags=re.M)

path.write_text(text)
PY

python3 - "$src/runners/CMakeLists.txt" <<'PY'
import re
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
keep = {"services"}
text = re.sub(
    r"^add_subdirectory\(([^)]+)\)",
    lambda m: m.group(0) if m.group(1) in keep else f"# ios-real-desktop-skip: {m.group(0)}",
    text,
    flags=re.M,
)
path.write_text(text)
PY

python3 - "$src/dataengines/CMakeLists.txt" <<'PY'
import re
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
if not path.exists():
    sys.exit(0)  # Plasma 6.7 dropped plasma-workspace/dataengines
text = path.read_text()
text = re.sub(
    r"^add_subdirectory\(([^)]+)\)",
    lambda m: m.group(0) if m.group(1) in {"time", "powermanagement"} else f"# ios-real-desktop-skip: {m.group(0)}",
    text,
    flags=re.M,
)
text = re.sub(
    r"^if \(PlasmaActivities_FOUND\)\n\s*add_subdirectory\(activities\)\nendif \(\)",
    "# ios-real-desktop-skip: PlasmaActivities dataengine",
    text,
    flags=re.M,
)
text = re.sub(
    r"^if \(KF6NetworkManagerQt_FOUND\)\n\s*add_subdirectory\(geolocation\)\nendif \(\)",
    "# ios-real-desktop-skip: NetworkManager geolocation dataengine",
    text,
    flags=re.M,
)
path.write_text(text)
PY

python3 - "$src/applets/CMakeLists.txt" <<'PY'
import re
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
# Every applet whose plugin links only KF6/Qt/Plasma. The old four-applet list
# was first-light triage and left visible holes: no battery readout, and a systray
# configured for a clipboard applet that wasn't installed, which is what draws the
# "?" badge on the tray clipboard icon.
#
# Excluded, each for a checked reason:
#   systemmonitor    KSysGuard::Sensors     no KSysGuard port; fails at cmake generate
#   devicenotifier   KSysGuard::ProcessCore ditto (and an iPad has no removable media)
#   cameraindicator  gated on KPipeWire upstream already
#   brightness       powerdevil DOES now export the
#                    org.kde.Solid.PowerManagement.Actions.BrightnessControl object
#                    this applet drives (XiosBacklightDetector, see
#                    powerdevil-ios-fixes.sh), so the KDE side of the chain is in
#                    place. What is still missing is the last hop to the panel:
#                    BKSDisplayBrightnessSet is inert on iPadOS 17.6.1 from a
#                    non-SpringBoard process -- symbols resolve, the brightness
#                    transaction creates, the entitlement is present, and
#                    BKSDisplayBrightnessGetCurrent never budges, with or without
#                    auto-brightness. Until that is replaced (UIScreen.brightness
#                    from Xios.app is the promising route), this applet would show a
#                    slider that moves nothing. Enabling it would also collide with
#                    plasma-mobile's qmldir for the same QML URI, so retire that
#                    stand-in at the same time.
keep_subdirs = {
    "digital-clock", "kicker", "notifications", "systemtray",
    "batterymonitor", "calendar",
    "mediacontroller", "panelspacer", "keyboardindicator", "appmenu", "icon",
}
# Substring-matched against the whole plasma_install_package() argument list.
# Applets pulled in via keep_subdirs install their own package from their own
# CMakeLists, so they need no entry here.
keep_packages = {
    "org.kde.plasma.digitalclock", "org.kde.plasma.notifications",
    "org.kde.plasma.activitybar", "org.kde.plasma.analogclock",
    "org.kde.plasma.lock_logout", "org.kde.plasma.manage-inputmethod",
    "org.kde.plasma.clipboard",
}

text = re.sub(
    r"^add_subdirectory\(([^)]+)\)",
    lambda m: m.group(0) if m.group(1) in keep_subdirs else f"# ios-firstlight-skip: {m.group(0)}",
    text,
    flags=re.M,
)
text = re.sub(
    r"^plasma_install_package\(([^)]+)\)",
    lambda m: m.group(0) if any(pkg in m.group(1) for pkg in keep_packages) else f"# ios-firstlight-skip: {m.group(0)}",
    text,
    flags=re.M,
)
path.write_text(text)
PY

python3 - "$src/components/CMakeLists.txt" <<'PY'
import re
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
keep = {
    "batterycontrol",
    "calendar",
    "containmentlayoutmanager",
    "dbus",
    "shellprivate",
    "keyboardlayout",
    "lookandfeelqml",
    "sessionsprivate",
    "trianglemousefilter",
    "workspace",
}
text = re.sub(r"^add_subdirectory\(([^)]+)\)",
              lambda m: m.group(0) if m.group(1) in keep else f"# ios-firstlight-skip: {m.group(0)}",
              text, flags=re.M)
path.write_text(text)
PY

python3 - "$src/klipper/CMakeLists.txt" "$src/klipper/klipper.cpp" \
  "$src/klipper/klipper.h" "$src/klipper/clipboardjob.cpp" \
  "$src/klipper/clipboardengine.cpp" \
  "$src/applets/clipboard/contents/ui/ClipboardPage.qml" \
  "$src/klipper/urlgrabber.cpp" "$src/klipper/klipperpopup.cpp" <<'PY'
import re
import sys
from xios_fixlib import Path, todo

(
    cmake,
    klipper_cpp,
    klipper_h,
    job_cpp,
    engine_cpp,
    clipboard_page,
    urlgrabber_cpp,
    popup_cpp,
) = map(Path, sys.argv[1:])

text = cmake.read_text()
text = text.replace("    KF6::Prison\n", "")
cmake.write_text(text)

text = klipper_cpp.read_text()
text = text.replace("#include <Prison/Barcode>\n", "")
text = re.sub(
    r"\n    // add barcode for mobile phones\n"
    r"    m_showBarcodeAction = .*?\n"
    r"    \}\);\n",
    "\n",
    text,
    count=1,
    flags=re.S,
)
if "\nclass BarcodeLabel : public QLabel" in text:  # 6.1 only: 6.7 moved the barcode UI to QML (KF6::Prison link in CMake)
    start = text.index("\nclass BarcodeLabel : public QLabel")
    end = text.index("\nvoid Klipper::slotAskClearHistory()", start)
    text = text[:start] + "\n" + text[end:]
klipper_cpp.write_text(text)

text = klipper_h.read_text()
text = text.replace("    void showBarcode(std::shared_ptr<const HistoryItem> item);\n", "")
text = text.replace("    QAction *m_showBarcodeAction;\n", "")
klipper_h.write_text(text)

text = job_cpp.read_text()
text = text.replace("#include <Prison/Barcode>\n", "")
text = re.sub(
    r'    \} else if \(operation == QLatin1String\("barcode"\)\) \{.*?'
    r'    \} else if \(operation == QLatin1String\("action"\)\) \{',
    '    } else if (operation == QLatin1String("barcode")) {\n'
    '        setResult(false);\n'
    '        return;\n'
    '    } else if (operation == QLatin1String("action")) {',
    text,
    count=1,
    flags=re.S,
)
job_cpp.write_text(text)

text = engine_cpp.read_text()
text = text.replace(
    "setData(s_clipboardSourceName, s_barcodeKey, true);",
    "setData(s_clipboardSourceName, s_barcodeKey, false);",
)
engine_cpp.write_text(text)

text = clipboard_page.read_text()
text = re.sub(
    r"^    supportsBarcodes: \{.*?^    \}\n"
    r"    onItemSelected:",
    "    supportsBarcodes: false\n"
    "    onItemSelected:",
    text,
    count=1,
    flags=re.M | re.S,
)
clipboard_page.write_text(text)

# Klipper's clipboard data engine is useful on Wayland, but its legacy popup
# helpers still include X11-only KWindowInfo/NETWM headers. Keep the portable
# history, actions and data-engine path; only drop the active-X11-window
# blacklist lookup and X11 popup-screen selection.
text = urlgrabber_cpp.read_text()
text = text.replace("#include <netwm.h>\n\n", "")
text = text.replace("#include <KWindowInfo>\n", "")
text = text.replace("#include <KX11Extras>\n", "")
text = text.replace(
    """bool URLGrabber::isAvoidedWindow() const
{
    const WId active = KX11Extras::activeWindow();
    if (!active) {
        return false;
    }
    KWindowInfo info(active, NET::Properties(), NET::WM2WindowClass);
    return m_myAvoidWindows.contains(QString::fromLatin1(info.windowClassName()));
}""",
    """bool URLGrabber::isAvoidedWindow() const
{
    return false;
}""",
)
urlgrabber_cpp.write_text(text)

text = popup_cpp.read_text()
text = text.replace("#include <KWindowInfo>\n", "")
text = text.replace("#include <KWindowSystem>\n", "")
text = text.replace(
    """    QScreen *screen = nullptr;
    if (KWindowSystem::isPlatformX11()) {
        KWindowInfo windowInfo(winId(), NET::WMGeometry);
        QRect geometry = windowInfo.geometry();
        screen = QGuiApplication::screenAt(geometry.center());
    }
    if (screen == nullptr) {
        screen = QGuiApplication::screens()[0];
    }""",
    """    QScreen *screen = QGuiApplication::primaryScreen();
    Q_ASSERT(screen);""",
)
popup_cpp.write_text(text)
PY

python3 - "$src/kcms/CMakeLists.txt" <<'PY'
import re
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
keep = {
    "krdb",
    "desktoptheme",
    "icons",
    "style",
    "lookandfeel",
    "colors",
    "wallpaper",
}
text = re.sub(
    r"^add_subdirectory\(\s*([^) ]+)\s*\)",
    lambda m: m.group(0) if m.group(1) in keep else f"# ios-kcm-wave-skip: {m.group(0)}",
    text,
    flags=re.M,
)
text = re.sub(
    r"^if\(KF6UserFeedback_FOUND\)\n\s*add_subdirectory\(feedback\)\nendif\(\)",
    "# ios-kcm-wave-skip: feedback KCM needs KF6UserFeedback",
    text,
    flags=re.M,
)
text = re.sub(
    r"^if\(X11_Xcursor_FOUND\)\n\s*add_subdirectory\(cursortheme\)\nendif\(\)",
    "# ios-kcm-wave-skip: cursor theme KCM is X11-specific",
    text,
    flags=re.M,
)
text = re.sub(
    r"^if\(FONTCONFIG_FOUND\)\n\s*add_subdirectory\( kfontinst \)\n\s*add_subdirectory\( fonts \)\nendif\(\)",
    "# ios-kcm-wave-skip: font KCMs need a separate non-X11 pass",
    text,
    flags=re.M,
)
path.write_text(text)
PY

python3 - "$src/startkde/CMakeLists.txt" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
path.write_text("""add_subdirectory(plasmaautostart)
add_subdirectory(plasma-shutdown)
""")
PY

python3 - "$src/kcms/krdb/CMakeLists.txt" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    "target_link_libraries(krdb PRIVATE Qt::Widgets Qt::DBus KF6::CoreAddons KF6::DBusAddons KF6::GuiAddons KF6::I18n KF6::WindowSystem KF6::ConfigWidgets X11::X11 Qt::GuiPrivate)",
    "target_link_libraries(krdb PRIVATE Qt::Widgets Qt::DBus KF6::CoreAddons KF6::DBusAddons KF6::GuiAddons KF6::I18n KF6::WindowSystem KF6::ConfigWidgets)\nif(HAVE_X11)\n    target_link_libraries(krdb PRIVATE X11::X11 Qt::GuiPrivate)\nendif()",
)
# 6.7 shape: ColorScheme replaced ConfigWidgets, and X11::X11 sits in the always-on list.
text = text.replace(
    "target_link_libraries(krdb PRIVATE Qt::Widgets Qt::DBus KF6::CoreAddons KF6::DBusAddons KF6::GuiAddons KF6::I18n KF6::WindowSystem KF6::ColorScheme X11::X11 Qt::GuiPrivate)",
    "target_link_libraries(krdb PRIVATE Qt::Widgets Qt::DBus KF6::CoreAddons KF6::DBusAddons KF6::GuiAddons KF6::I18n KF6::WindowSystem KF6::ColorScheme Qt::GuiPrivate)\nif(HAVE_X11)\n    target_link_libraries(krdb PRIVATE X11::X11)\nendif()",
)
path.write_text(text)
PY

# 6.7 libnotificationmanager plays notification sounds through libcanberra (new since 6.1). No canberra on iOS yet:
# compile the sound path out (XIOS_NO_CANBERRA); notifications still show, they are silent. See plan section 9.
python3 - "$src/libnotificationmanager/CMakeLists.txt" "$src/libnotificationmanager/notifications.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

cm = Path(sys.argv[1])
text = cm.read_text()
if "XIOS_NO_CANBERRA" not in text:
    if "        Canberra::Canberra\n)" in text:
        text = text.replace("        Canberra::Canberra\n)",
            ")\nif(Canberra_FOUND)\n    target_link_libraries(notificationmanager PRIVATE Canberra::Canberra)\nelse()\n    target_compile_definitions(notificationmanager PRIVATE XIOS_NO_CANBERRA=1)\nendif()", 1)
        cm.write_text(text)
    else:
        todo("notificationmanager Canberra link marker not found")

src = Path(sys.argv[2])
text = src.read_text()
if "XIOS_NO_CANBERRA" not in text:
    text = text.replace("#include <canberra.h>\n", "#ifndef XIOS_NO_CANBERRA\n#include <canberra.h>\n#endif\n", 1)
    text = text.replace("    ca_context *canberraContext = nullptr;\n", "#ifndef XIOS_NO_CANBERRA\n    ca_context *canberraContext = nullptr;\n#endif\n", 1)
    text = text.replace("    if (!d->canberraContext) {\n", "#ifdef XIOS_NO_CANBERRA\n    return;\n#else\n    if (!d->canberraContext) {\n", 1)
    tail = '                                       << "with canberra:" << ca_strerror(ret);\n        return;\n    }\n}\n'
    if tail in text:
        text = text.replace(tail, tail[:-2] + "#endif\n}\n", 1)
    else:
        todo("notifications.cpp canberra tail marker not found")
    src.write_text(text)
PY

python3 - "$src/kcms/colors/CMakeLists.txt" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("if(HAVE_X11)\n    target_link_libraries(kcm_colors PRIVATE X11::X11 Qt::GuiPrivate)\nendif()\n", "")
text = text.replace("    Qt::GuiPrivate\n", "")
text = text.replace("    X11::X11\n", "")
path.write_text(text)
PY

python3 - "$src/kcms/lookandfeel/kcm.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#include <private/qtx11extras_p.h>\n", "#if defined(HAVE_X11) && HAVE_X11\n#include <private/qtx11extras_p.h>\n#endif\n")
text = text.replace("#include <X11/Xlib.h>\n", "#if defined(HAVE_X11) && HAVE_X11\n#include <X11/Xlib.h>\n#endif\n")
path.write_text(text)
PY

python3 - "$src/components/sessionsprivate/CMakeLists.txt" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
if "xios fallback ScreenSaver DBus interface" not in text:
    text = text.replace(
        "set(sessionsprivateplugin_SRCS\n",
        "if(NOT SCREENSAVER_DBUS_INTERFACE)\n"
        "    # xios fallback ScreenSaver DBus interface until kscreenlocker is ported.\n"
        "    set(SCREENSAVER_DBUS_INTERFACE \"${plasma-workspace_SOURCE_DIR}/iosc-dbus-interfaces/kf6_org.freedesktop.ScreenSaver.xml\")\n"
        "endif()\n\n"
        "set(sessionsprivateplugin_SRCS\n",
    )
path.write_text(text)
PY

python3 - "$src/logout-greeter/CMakeLists.txt" "$src/logout-greeter/shutdowndlg.cpp" <<'PY'
import re
import sys
from xios_fixlib import Path, todo

cmake = Path(sys.argv[1])
text = cmake.read_text()
text = text.replace("    X11::X11\n", "")
if "target_link_libraries(ksmserver-logout-greeter Qt::GuiPrivate)" in text:
    text = text.replace("target_link_libraries(ksmserver-logout-greeter Qt::GuiPrivate)", "if(HAVE_X11)\n    target_link_libraries(ksmserver-logout-greeter X11::X11 Qt::GuiPrivate)\nendif()")
cmake.write_text(text)

source = Path(sys.argv[2])
text = source.read_text()
text = text.replace("\n#include <config-workspace.h>\n", "\n")
text = text.replace('#include "shutdowndlg.h"\n', '#include "shutdowndlg.h"\n#include <config-workspace.h>\n')
for header in ["#include <private/qtx11extras_p.h>\n", "#include <KX11Extras>\n", "#include <netwm.h>\n"]:
    text = text.replace(header, f"#if defined(HAVE_X11) && HAVE_X11\n{header}#endif\n")
text = text.replace("#include <X11/Xatom.h>\n#include <X11/Xutil.h>\n#include <fixx11h.h>\n", "#if defined(HAVE_X11) && HAVE_X11\n#include <X11/Xatom.h>\n#include <X11/Xutil.h>\n#include <fixx11h.h>\n#endif\n")
for header in ["#include <private/qtx11extras_p.h>\n", "#include <KX11Extras>\n", "#include <netwm.h>\n"]:
    text = re.sub(
        rf"(?:#if defined\(HAVE_X11\) && HAVE_X11\n)+{re.escape(header)}(?:#endif\n)+",
        f"#if defined(HAVE_X11) && HAVE_X11\n{header}#endif\n",
        text,
    )
text = re.sub(
    r"(?:#if defined\(HAVE_X11\) && HAVE_X11\n)+#include <X11/Xatom\.h>\n#include <X11/Xutil\.h>\n#include <fixx11h\.h>\n(?:#endif\n)+",
    "#if defined(HAVE_X11) && HAVE_X11\n#include <X11/Xatom.h>\n#include <X11/Xutil.h>\n#include <fixx11h.h>\n#endif\n",
    text,
)
old = """    if (KWindowSystem::isPlatformX11()) {
        XChangeProperty(QX11Info::display(),
                        winId(),
                        XInternAtom(QX11Info::display(), "WM_WINDOW_ROLE", False),
                        XA_STRING,
                        8,
                        PropModeReplace,
                        (unsigned char *)"logoutdialog",
                        strlen("logoutdialog"));

        XClassHint classHint;
        classHint.res_name = const_cast<char *>("ksmserver-logout-greeter");
        classHint.res_class = const_cast<char *>("ksmserver-logout-greeter");
        XSetClassHint(QX11Info::display(), winId(), &classHint);
        KX11Extras::setState(winId(), NET::SkipTaskbar | NET::SkipPager | NET::SkipSwitcher);
    }
"""
new = """#if defined(HAVE_X11) && HAVE_X11
    if (KWindowSystem::isPlatformX11()) {
        XChangeProperty(QX11Info::display(),
                        winId(),
                        XInternAtom(QX11Info::display(), "WM_WINDOW_ROLE", False),
                        XA_STRING,
                        8,
                        PropModeReplace,
                        (unsigned char *)"logoutdialog",
                        strlen("logoutdialog"));

        XClassHint classHint;
        classHint.res_name = const_cast<char *>("ksmserver-logout-greeter");
        classHint.res_class = const_cast<char *>("ksmserver-logout-greeter");
        XSetClassHint(QX11Info::display(), winId(), &classHint);
        KX11Extras::setState(winId(), NET::SkipTaskbar | NET::SkipPager | NET::SkipSwitcher);
    }
#endif
"""
if old in text:
    text = text.replace(old, new)
elif "KX11Extras::setState(winId(), NET::SkipTaskbar | NET::SkipPager | NET::SkipSwitcher);" not in text:
    todo("logout greeter X11 window metadata block not found")
old = """    if (KX11Extras::compositingActive()) {
        // TODO: reenable window mask when we are without composite?
        //        clearMask();
    } else {
        //        setMask(m_view->mask());
    }
"""
new = """#if defined(HAVE_X11) && HAVE_X11
    if (KX11Extras::compositingActive()) {
        // TODO: reenable window mask when we are without composite?
        //        clearMask();
    } else {
        //        setMask(m_view->mask());
    }
#endif
"""
if old in text:
    text = text.replace(old, new)
elif "KX11Extras::compositingActive()" not in text:
    todo("logout greeter compositing block not found")
source.write_text(text)
PY

for layout in \
  "$src/lookandfeel/org.kde.breeze/contents/layouts/org.kde.plasma.desktop-layout.js" \
  "$src/lookandfeel/org.kde.breezedark/contents/layouts/org.kde.plasma.desktop-layout.js" \
  "$src/lookandfeel/org.kde.breezetwilight/contents/layouts/org.kde.plasma.desktop-layout.js"; do
  [ -f "$layout" ] || continue
  python3 - "$layout" <<'PY'
import re
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(
    r"desktopsArray\[j\]\.wallpaperPlugin = 'org\.kde\.(?:image|color)';",
    """desktopsArray[j].wallpaperPlugin = 'org.kde.image';
    desktopsArray[j].currentConfigGroup = Array('Wallpaper', 'org.kde.image', 'General');
    desktopsArray[j].writeConfig('Image', 'file:///var/jb/usr/share/backgrounds/xios/xios-default.png');
    desktopsArray[j].writeConfig('PreviewImage', 'file:///var/jb/usr/share/backgrounds/xios/xios-default.png');
    desktopsArray[j].writeConfig('FillMode', 2);""",
    text,
)
path.write_text(text)
PY
done

perl -0pi -e 's/add_subdirectory\(test\)/# ios-firstlight-skip: add_subdirectory(test)/g' "$src/libdbusmenuqt/CMakeLists.txt"
perl -0pi -e 's/add_subdirectory\(kconf_update\)/# ios-firstlight-skip: add_subdirectory(kconf_update)/g' "$src/shell/CMakeLists.txt"
perl -0pi -e 's/add_subdirectory\(wallpaperfileitemactionplugin\)/# ios-firstlight-skip: add_subdirectory(wallpaperfileitemactionplugin)/g' "$src/wallpapers/image/CMakeLists.txt"

python3 - "$src/kioworkers/CMakeLists.txt" <<'PY'
import re
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(
    r"^add_subdirectory\(([^)]+)\)",
    # desktop:/ worker needs KIO's KDirNotify/ForwardingWorkerBase, which exist only with USE_DBUS=ON in kio (our kio is
    # built without it, like every KF6 unit on Apple). Nothing on the iPad uses desktop:/ yet; see plan section 9.
    lambda m: f"# ios-firstlight-skip: {m.group(0)}",
    text,
    flags=re.M,
)
path.write_text(text)
PY

python3 - "$src/kioworkers/desktop/CMakeLists.txt" "$src/kioworkers/desktop/kio_desktop.cpp" "$src/kioworkers/desktop/desktopnotifier.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

cmake = Path(sys.argv[1])
text = cmake.read_text()
marker = "# iOS cross-build: use KIO's generated KDirNotify header from the staged source tree"
if marker not in text:
    text = text.replace(
        "include_directories(${CMAKE_CURRENT_BINARY_DIR})\n",
        "include_directories(${CMAKE_CURRENT_BINARY_DIR})\n"
        f"{marker}\n"
        "include_directories(${plasma-workspace_SOURCE_DIR}/../kio/src/core)\n",
    )
cmake.write_text(text)

kio = Path(sys.argv[2])
text = kio.read_text()
text = text.replace("#include <KDirNotify>", "#include <kdirnotify.h>")
text = text.replace(
    """    org::kde::kded6 kded(QStringLiteral("org.kde.kded6"), QStringLiteral("/kded"), QDBusConnection::sessionBus());
    auto pending = kded.loadModule("desktopnotifier");
    pending.waitForFinished();
""",
    """    // iOS first-light skips the desktopnotifier KDED sidecar; desktop:/ remains usable.
""",
)
kio.write_text(text)

notifier = Path(sys.argv[3])
text = notifier.read_text()
text = text.replace("#include <KDirNotify>", "#include <kdirnotify.h>")
notifier.write_text(text)
PY

python3 - "$src/shell/CMakeLists.txt" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
moc_marker = "# iOS cross-build: qdbusxml2cpp sources include generated moc files"
if moc_marker not in text:
    needle = "qt_add_dbus_interface(plasma_shell_SRCS ${krunner_xml} krunner_interface)\n\n\n"
    if needle not in text:
        todo("plasmashell DBus interface marker not found")
    text = text.replace(
        needle,
        needle
        + f"""{moc_marker}; make the dependency explicit so Ninja does not race
# the qdbusxml2cpp compile before moc generation.
set_source_files_properties(
    ${{CMAKE_CURRENT_BINARY_DIR}}/plasmashelladaptor.cpp
    PROPERTIES OBJECT_DEPENDS ${{CMAKE_CURRENT_BINARY_DIR}}/moc_plasmashelladaptor.cpp
)
set_source_files_properties(
    ${{CMAKE_CURRENT_BINARY_DIR}}/krunner_interface.cpp
    PROPERTIES OBJECT_DEPENDS ${{CMAKE_CURRENT_BINARY_DIR}}/moc_krunner_interface.cpp
)

# iOS cross-build: generated logging headers are included by ordinary sources;
# make the dependency explicit so Ninja does not race those compiles.
set_source_files_properties(
    main.cpp
    panelshadows.cpp
    panelview.cpp
    osd.cpp
    shellcorona.cpp
    autohidescreenedge.cpp
    scripting/appinterface.cpp
    scripting/configgroup.cpp
    scripting/scriptengine.cpp
    scripting/scriptengine_v1.cpp
    PROPERTIES OBJECT_DEPENDS ${{CMAKE_CURRENT_BINARY_DIR}}/debug.h
)
set_source_files_properties(
    screenpool.cpp
    PROPERTIES OBJECT_DEPENDS ${{CMAKE_CURRENT_BINARY_DIR}}/screenpool-debug.h
)

""",
    )
marker = "# iOS first-light QML import shims"
if marker not in text:
    needle = "install( FILES dbus/org.kde.PlasmaShell.xml DESTINATION ${KDE_INSTALL_DBUSINTERFACEDIR} )\n"
    if needle not in text:
        todo("plasmashell DBus install marker not found")
    text = text.replace(
        needle,
        needle
        + f"""
{marker}: these modules are registered by plasmashell at runtime, but QML still
# needs importable qmldir markers when resolving upstream shell package imports.
file(MAKE_DIRECTORY ${{CMAKE_CURRENT_BINARY_DIR}}/ios-qml/org/kde/plasma/shell/panel)
file(WRITE ${{CMAKE_CURRENT_BINARY_DIR}}/ios-qml/org/kde/plasma/shell/qmldir "module org.kde.plasma.shell\\n")
file(WRITE ${{CMAKE_CURRENT_BINARY_DIR}}/ios-qml/org/kde/plasma/shell/panel/qmldir "module org.kde.plasma.shell.panel\\n")
install(FILES ${{CMAKE_CURRENT_BINARY_DIR}}/ios-qml/org/kde/plasma/shell/qmldir DESTINATION ${{KDE_INSTALL_QMLDIR}}/org/kde/plasma/shell)
install(FILES ${{CMAKE_CURRENT_BINARY_DIR}}/ios-qml/org/kde/plasma/shell/panel/qmldir DESTINATION ${{KDE_INSTALL_QMLDIR}}/org/kde/plasma/shell/panel)
""",
    )
path.write_text(text)
PY

python3 - "$src/libnotificationmanager/CMakeLists.txt" "$src/libnotificationmanager/mirroredscreenstracker_p.h" <<'PY'
import sys
from xios_fixlib import Path, todo

cmake = Path(sys.argv[1])
text = cmake.read_text()
text = text.replace("        KF6::Screen\n", "")
cmake.write_text(text)

header = Path(sys.argv[2])
text = header.read_text()
text = text.replace("#include <KScreen/Config>\n", "")
header.write_text(text)
PY

python3 - "$src/libnotificationmanager/server.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#include <KStartupInfo>\n", "#if !defined(__APPLE__)\n#include <KStartupInfo>\n#endif\n")
text = text.replace(
    """        KStartupInfoId startupId;
        startupId.initId();

        Q_EMIT d->ActivationToken(notificationId, QString::fromUtf8(startupId.id()));
""",
    """#if !defined(__APPLE__)
        KStartupInfoId startupId;
        startupId.initId();

        Q_EMIT d->ActivationToken(notificationId, QString::fromUtf8(startupId.id()));
#else
        Q_EMIT d->ActivationToken(notificationId, QString());
#endif
""",
)
path.write_text(text)
PY

python3 - "$src/applets/notifications/notificationapplet.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#include <KX11Extras>\n", "#if !defined(__APPLE__)\n#include <KX11Extras>\n#endif\n")
text = text.replace(
    """    if (window && window->winId()) {
        KX11Extras::forceActiveWindow(window->winId());
    }
""",
    """#if !defined(__APPLE__)
    if (window && window->winId()) {
        KX11Extras::forceActiveWindow(window->winId());
    }
#else
    if (window) {
        window->requestActivate();
    }
#endif
""",
)
path.write_text(text)
PY

python3 - "$src/applets/digital-clock/plugin/CMakeLists.txt" "$src/applets/digital-clock/plugin/timezonesi18n.h" "$src/applets/digital-clock/plugin/timezonesi18n.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

cmake = Path(sys.argv[1])
text = cmake.read_text()
text = text.replace("        ICU::i18n\n", "")
text = text.replace("        ICU::uc\n", "")
text = text.replace("        Qt::Qml\n        Qt::Widgets", "        Qt::Qml\n        Qt::DBus\n        Qt::Widgets")
cmake.write_text(text)

header = Path(sys.argv[2])
text = header.read_text()
text = text.replace("#include <unicode/tznames.h>\n\n", "")
text = text.replace("    QScopedPointer<icu::TimeZoneNames> m_tzNames;\n", "")
header.write_text(text)

source = Path(sys.argv[3])
text = source.read_text()
text = text.replace("#include <unicode/localebuilder.h>\n\n", "")
text = text.replace(
    """    if (!m_tzNames) {
        return timezoneId;
    }

    icu::UnicodeString result;
    const auto &cityName = m_tzNames->getExemplarLocationName(icu::UnicodeString::fromUTF8(icu::StringPiece(timezoneId.toStdString())), result);

    return cityName.isBogus() ? timezoneId : QStringView(cityName.getBuffer(), cityName.length()).toString();
""",
    """    const QString city = timezoneId.section(QLatin1Char('/'), -1).replace(QLatin1Char('_'), QLatin1Char(' '));
    return city.isEmpty() ? timezoneId : city;
""",
)
import re as _re
# 6.7 spells the locale as ...toLatin1().constData(): match both.
text = _re.sub(r"    const auto locale = icu::Locale\(QLocale::system\(\)\.name\(\)\.toLatin1\(\)(?:\.constData\(\))?\);\n"
               r"    UErrorCode error = U_ZERO_ERROR;\n.*?\n    \}\n\n", "", text, flags=_re.S, count=1)
source.write_text(text)
PY

python3 - "$src/applets/kicker/plugin/rootmodel.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    """    , m_favorites(new KAStatsFavoritesModel(this))
    , m_systemModel(nullptr)
""",
    """    , m_favorites(new KAStatsFavoritesModel(this))
    , m_systemModel(new SystemModel(this))
""",
)
text = text.replace(
    """    m_systemModel = new SystemModel(this);
    QObject::connect(m_systemModel, &SystemModel::sessionManagementStateChanged, this, &RootModel::refresh);
""",
    """    if (!m_systemModel) {
        m_systemModel = new SystemModel(this);
    }
    QObject::disconnect(m_systemModel, &SystemModel::sessionManagementStateChanged, this, &RootModel::refresh);
    QObject::connect(m_systemModel, &SystemModel::sessionManagementStateChanged, this, &RootModel::refresh);
""",
)
path.write_text(text)
PY

python3 - "$src/shell/main.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
marker = 'org.kde.KActivities.core.disableAutostart'
if marker not in text:
    text = text.replace(
        "    QApplication app(argc, argv);\n",
        """    QApplication app(argc, argv);
#if defined(__APPLE__)
    if (qEnvironmentVariableIsSet("XIOS_KDE_NO_KAMD")) {
        app.setProperty("org.kde.KActivities.core.disableAutostart", true);
    }
#endif
""",
    )
path.write_text(text)
PY

mkdir -p "$src/iosc-dbus-interfaces"
cat > "$src/iosc-dbus-interfaces/kf6_org.freedesktop.ScreenSaver.xml" <<'XML'
<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
 "https://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
<node>
  <interface name="org.freedesktop.ScreenSaver">
    <method name="Lock"/>
    <method name="GetActive">
      <arg name="active" type="b" direction="out"/>
    </method>
    <signal name="ActiveChanged">
      <arg name="active" type="b"/>
    </signal>
  </interface>
</node>
XML
python3 - "$src/libkworkspace/CMakeLists.txt" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("set(kworkspace_LIB_SRCS kdisplaymanager.cpp",
                    'set(KSCREENLOCKER_DBUS_INTERFACES_DIR "${plasma-workspace_SOURCE_DIR}/iosc-dbus-interfaces")\nset(kworkspace_LIB_SRCS kdisplaymanager.cpp')
path.write_text(text)
PY

python3 - "$src/libkworkspace/outputorderwatcher.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
if "\nX11OutputOrderWatcher::X11OutputOrderWatcher" in text:
    start = text.index("\nX11OutputOrderWatcher::X11OutputOrderWatcher")
    end = text.index("\nWaylandOutputOrderWatcher::WaylandOutputOrderWatcher")
    x11_impl = text[start:end]
    if "#if defined(HAVE_X11) && HAVE_X11" not in x11_impl:
        text = text[:start] + "\n#if defined(HAVE_X11) && HAVE_X11" + x11_impl + "#endif\n" + text[end:]
    path.write_text(text)
else:
    print("plasma-workspace-ios-fixes.sh: X11OutputOrderWatcher not in this source (6.7 restructure): skipped", file=sys.stderr)
PY

python3 - "$src/libkworkspace/sessionmanagementbackend.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    "#include <QMutex>\n#include <QMutexLocker>\n",
    "#include <QMutex>\n#include <QMutexLocker>\n#include <QFileInfo>\n#include <QProcess>\n#include <QStandardPaths>\n#include <QStringList>\n",
)
marker = "static SessionBackend *s_backend = nullptr;\n\n"
shim = r'''
#if defined(__APPLE__)
static QString xiosSessionBinary()
{
    const QStringList candidates = {
        QStringLiteral("/var/jb/usr/local/bin/xios-session"),
        QStringLiteral("/var/jb/usr/bin/xios-session"),
        QStringLiteral("/usr/local/bin/xios-session"),
        QStringLiteral("/usr/bin/xios-session"),
        QStandardPaths::findExecutable(QStringLiteral("xios-session")),
    };
    for (const QString &candidate : candidates) {
        if (!candidate.isEmpty() && QFileInfo(candidate).isExecutable()) {
            return candidate;
        }
    }
    return QString();
}

static void runXiosSession(const QStringList &arguments)
{
    const QString program = xiosSessionBinary();
    if (program.isEmpty()) {
        qWarning() << "xios-session is not installed; cannot perform session action" << arguments;
        return;
    }
    if (!QProcess::startDetached(program, arguments)) {
        qWarning() << "failed to start xios-session" << arguments;
    }
}

class XiosSessionBackend final : public SessionBackend
{
public:
    static bool exists()
    {
        return true;
    }

    SessionManagement::State state() const override
    {
        return SessionManagement::State::Ready;
    }

    void shutdown() override
    {
        runXiosSession({QStringLiteral("stop")});
    }
    void reboot() override
    {
        runXiosSession({QStringLiteral("stop")});
    }
    void suspend() override
    {
    }
    void hybridSuspend() override
    {
    }
    void hibernate() override
    {
    }
    void suspendThenHibernate() override
    {
    }

    // Shutdown/reboot both map to "xios-session stop" (end the Plasma
    // session); iOS owns actual device power. These gate the power-menu UI
    // paths (SessionManagement::requestShutdown early-returns when false),
    // so they must be true for the wired Mobile powermenu tile to act.
    bool canShutdown() const override
    {
        return true;
    }
    bool canReboot() const override
    {
        return true;
    }
    bool canSuspend() const override
    {
        return false;
    }
    bool canHybridSuspend() const override
    {
        return false;
    }
    bool canHibernate() const override
    {
        return false;
    }
    bool canSuspendThenHibernate() const override
    {
        return false;
    }
};
#endif

'''
if shim.strip() not in text:
    if marker not in text:
        todo("session backend singleton marker not found")
    text = text.replace(marker, marker + shim)
old = """    if (qEnvironmentVariableIntValue("PLASMA_SESSION_GUI_TEST")) {
        s_backend = new TestSessionBackend();
    } else if (LogindSessionBackend::exists()) {
        s_backend = new LogindSessionBackend();
    } else {
        s_backend = new DummySessionBackend();
    }
"""
new = """    if (qEnvironmentVariableIntValue("PLASMA_SESSION_GUI_TEST")) {
        s_backend = new TestSessionBackend();
    } else if (LogindSessionBackend::exists()) {
        s_backend = new LogindSessionBackend();
#if defined(__APPLE__)
    } else if (XiosSessionBackend::exists()) {
        s_backend = new XiosSessionBackend();
#endif
    } else {
        s_backend = new DummySessionBackend();
    }
"""
if old in text:
    text = text.replace(old, new)
elif "XiosSessionBackend::exists()" not in text:
    todo("SessionBackend::self selection block not found")
path.write_text(text)
PY

python3 - "$src/startkde/plasma-shutdown/shutdown.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
old = """    if (m_shutdownType == KWorkSpace::ShutdownTypeHalt) {
        SessionBackend::self()->shutdown();
    } else if (m_shutdownType == KWorkSpace::ShutdownTypeReboot) {
        SessionBackend::self()->reboot();
    } else { // logout
        qApp->quit();
    }
"""
new = """    if (m_shutdownType == KWorkSpace::ShutdownTypeHalt) {
        SessionBackend::self()->shutdown();
    } else if (m_shutdownType == KWorkSpace::ShutdownTypeReboot) {
        SessionBackend::self()->reboot();
    } else { // logout
#if defined(__APPLE__)
        SessionBackend::self()->shutdown();
#else
        qApp->quit();
#endif
    }
"""
if old in text:
    text = text.replace(old, new)
elif "SessionBackend::self()->shutdown();" not in text:
    todo("plasma-shutdown logoutComplete block not found")
path.write_text(text)
PY

python3 - "$src/libtaskmanager/virtualdesktopinfo.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#include <KX11Extras>\n", "#if defined(HAVE_X11) && HAVE_X11\n#include <KX11Extras>\n#endif\n")
if "\nnamespace X11Info\n" in text:
    start = text.index("\nnamespace X11Info\n")
    end = text.index("\nnamespace TaskManager\n")
    x11_info = text[start:end]
    if "#if defined(HAVE_X11) && HAVE_X11" not in x11_info:
        text = text[:start] + "\n#if defined(HAVE_X11) && HAVE_X11" + x11_info + "#endif\n" + text[end:]
path.write_text(text)
PY

python3 - "$src/libtaskmanager/waylandtasksmodel.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
old = """        int pipeFds[2];
        if (pipe2(pipeFds, O_CLOEXEC) != 0) {
            qCWarning(TASKMANAGER_DEBUG) << "failed creating pipe";
            return;
        }
"""
new = """        int pipeFds[2];
#if defined(__APPLE__)
        if (pipe(pipeFds) != 0) {
            qCWarning(TASKMANAGER_DEBUG) << "failed creating pipe";
            return;
        }
        fcntl(pipeFds[0], F_SETFD, FD_CLOEXEC);
        fcntl(pipeFds[1], F_SETFD, FD_CLOEXEC);
#else
        if (pipe2(pipeFds, O_CLOEXEC) != 0) {
            qCWarning(TASKMANAGER_DEBUG) << "failed creating pipe";
            return;
        }
#endif
"""
if old in text:
    text = text.replace(old, new)
elif "if (pipe(pipeFds) != 0)" not in text:
    todo("pipe2 block not found")
path.write_text(text)
PY

python3 - "$src/applets/kicker/plugin/dashboardwindow.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#include <KX11Extras>\n", "#if defined(HAVE_X11) && HAVE_X11\n#include <KX11Extras>\n#endif\n")
text = text.replace(
    """        showFullScreen();
        KX11Extras::forceActiveWindow(winId());
""",
    """        showFullScreen();
#if defined(HAVE_X11) && HAVE_X11
        if (KWindowSystem::isPlatformX11()) {
            KX11Extras::forceActiveWindow(winId());
        } else
#endif
        {
            requestActivate();
        }
""",
)
text = text.replace(
    """            if (KWindowSystem::isPlatformX11()) {
                KX11Extras::setState(winId(), NET::SkipTaskbar | NET::SkipPager | NET::SkipSwitcher);
            } else {
                if (m_plasmashell) {
                    auto *surface = KWayland::Client::Surface::fromQtWinId(winId());
                    auto *plasmashellSurface = KWayland::Client::PlasmaShellSurface::get(surface);

                    if (!plasmashellSurface) {
                        plasmashellSurface = m_plasmashell->createSurface(surface, this);
                    }

                    plasmashellSurface->setSkipSwitcher(true);
                    plasmashellSurface->setSkipTaskbar(true);
                }
            }
""",
    """#if defined(HAVE_X11) && HAVE_X11
            if (KWindowSystem::isPlatformX11()) {
                KX11Extras::setState(winId(), NET::SkipTaskbar | NET::SkipPager | NET::SkipSwitcher);
            } else
#endif
            {
                if (m_plasmashell) {
                    auto *surface = KWayland::Client::Surface::fromQtWinId(winId());
                    auto *plasmashellSurface = KWayland::Client::PlasmaShellSurface::get(surface);

                    if (!plasmashellSurface) {
                        plasmashellSurface = m_plasmashell->createSurface(surface, this);
                    }

                    plasmashellSurface->setSkipSwitcher(true);
                    plasmashellSurface->setSkipTaskbar(true);
                }
            }
""",
)
text = text.replace(
    """        if (isVisible()) {
            KX11Extras::forceActiveWindow(winId());
        }
""",
    """        if (isVisible()) {
#if defined(HAVE_X11) && HAVE_X11
            if (KWindowSystem::isPlatformX11()) {
                KX11Extras::forceActiveWindow(winId());
            } else
#endif
            {
                requestActivate();
            }
        }
""",
)
path.write_text(text)
PY

python3 - "$src/applets/kicker/plugin/windowsystem.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#include <KX11Extras>\n", "#if defined(HAVE_X11) && HAVE_X11\n#include <KX11Extras>\n#endif\n")
text = text.replace(
    """    KX11Extras::forceActiveWindow(item->window()->winId());
""",
    """#if defined(HAVE_X11) && HAVE_X11
    if (KWindowSystem::isPlatformX11()) {
        KX11Extras::forceActiveWindow(item->window()->winId());
        return;
    }
#endif
    item->window()->requestActivate();
""",
)
path.write_text(text)
PY

python3 - "$src/shell/panelview.cpp" "$src/shell/shellcorona.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

for name in sys.argv[1:]:
    path = Path(name)
    text = path.read_text()
    text = text.replace("#include <KX11Extras>\n", "#if defined(HAVE_X11) && HAVE_X11\n#include <KX11Extras>\n#endif\n")
    text = text.replace("""        if (!KWindowSystem::isPlatformX11() || KX11Extras::compositingActive()) {
            setMask(screenPanelRect);
        } else {
            setMask(mask);
        }
""", """#if defined(HAVE_X11) && HAVE_X11
        if (!KWindowSystem::isPlatformX11() || KX11Extras::compositingActive()) {
            setMask(screenPanelRect);
        } else {
            setMask(mask);
        }
#else
        setMask(screenPanelRect);
#endif
""")
    text = text.replace("""        if (KWindowSystem::isPlatformX11()) {
            KX11Extras::forceActiveWindow(winId());
        } else {
            showTemporarily();
        }
""", """#if defined(HAVE_X11) && HAVE_X11
        if (KWindowSystem::isPlatformX11()) {
            KX11Extras::forceActiveWindow(winId());
        } else
#endif
        {
            showTemporarily();
        }
""")
    path.write_text(text)
PY

python3 - "$src/shell/panelconfigview.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#if HAVE_X11\n#include <KX11Extras>\n#endif", "#if defined(HAVE_X11) && HAVE_X11\n#include <KX11Extras>\n#endif")
text = text.replace("""    if (KWindowSystem::isPlatformX11()) {
        KX11Extras::setType(winId(), NET::Dock);
        KX11Extras::setState(winId(), NET::KeepAbove);
        switch (m_containment->location()) {
        case Plasma::Types::TopEdge:
            setPosition(available.topLeft() + screen()->geometry().topLeft());
            break;
        case Plasma::Types::LeftEdge:
            setPosition(available.topLeft() + screen()->geometry().topLeft());
            break;
        case Plasma::Types::RightEdge:
            setPosition(available.topLeft() + screen()->geometry().topRight() - QPoint(width(), 0));
            break;
        case Plasma::Types::BottomEdge:
        default:
            setPosition(available.bottomLeft() + screen()->geometry().topLeft() - QPoint(0, height()));
        }
    } else if (m_layerWindow) {
""", """#if defined(HAVE_X11) && HAVE_X11
    if (KWindowSystem::isPlatformX11()) {
        KX11Extras::setType(winId(), NET::Dock);
        KX11Extras::setState(winId(), NET::KeepAbove);
        switch (m_containment->location()) {
        case Plasma::Types::TopEdge:
            setPosition(available.topLeft() + screen()->geometry().topLeft());
            break;
        case Plasma::Types::LeftEdge:
            setPosition(available.topLeft() + screen()->geometry().topLeft());
            break;
        case Plasma::Types::RightEdge:
            setPosition(available.topLeft() + screen()->geometry().topRight() - QPoint(width(), 0));
            break;
        case Plasma::Types::BottomEdge:
        default:
            setPosition(available.bottomLeft() + screen()->geometry().topLeft() - QPoint(0, height()));
        }
    } else
#endif
    if (m_layerWindow) {
""")
text = text.replace("""    if (KWindowSystem::isPlatformX11()) {
        KX11Extras::setType(winId(), NET::AppletPopup);
    } else {
        PlasmaShellWaylandIntegration::get(this)->setRole(QtWayland::org_kde_plasma_surface::role::role_appletpopup);
    }
""", """#if defined(HAVE_X11) && HAVE_X11
    if (KWindowSystem::isPlatformX11()) {
        KX11Extras::setType(winId(), NET::AppletPopup);
    } else
#endif
    {
        PlasmaShellWaylandIntegration::get(this)->setRole(QtWayland::org_kde_plasma_surface::role::role_appletpopup);
    }
""")
path.write_text(text)
PY

python3 - "$src/shell/desktopview.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#include <qopenglshaderprogram.h>\n", "")
text = text.replace("#include <KStartupInfo>\n", "#if defined(HAVE_X11) && HAVE_X11\n#include <KStartupInfo>\n#endif\n")
text = text.replace("#include <KX11Extras>\n", "#if defined(HAVE_X11) && HAVE_X11\n#include <KX11Extras>\n#endif\n")
text = text.replace("""    if (KWindowSystem::isPlatformWayland()) {
        m_layerWindow = LayerShellQt::Window::get(this);
        m_layerWindow->setKeyboardInteractivity(LayerShellQt::Window::KeyboardInteractivityOnDemand);
        m_layerWindow->setExclusiveZone(-1);
        m_layerWindow->setLayer(LayerShellQt::Window::LayerBackground);
        m_layerWindow->setScope(QStringLiteral("desktop"));
        m_layerWindow->setCloseOnDismissed(false);
    } else {
        KX11Extras::setType(winId(), NET::Desktop);
        KX11Extras::setState(winId(), NET::KeepBelow);
    }
""", """    if (KWindowSystem::isPlatformWayland()) {
        m_layerWindow = LayerShellQt::Window::get(this);
        m_layerWindow->setKeyboardInteractivity(LayerShellQt::Window::KeyboardInteractivityOnDemand);
        m_layerWindow->setExclusiveZone(-1);
        m_layerWindow->setLayer(LayerShellQt::Window::LayerBackground);
        m_layerWindow->setScope(QStringLiteral("desktop"));
        m_layerWindow->setCloseOnDismissed(false);
    }
#if defined(HAVE_X11) && HAVE_X11
    else {
        KX11Extras::setType(winId(), NET::Desktop);
        KX11Extras::setState(winId(), NET::KeepBelow);
    }
#endif
""")
text = text.replace("""            if (window && qGuiApp->nativeInterface<QNativeInterface::QX11Application>()) {
                KStartupInfo::setNewStartupId(window, qgetenv("DESKTOP_STARTUP_ID"));
            }
""", """#if defined(HAVE_X11) && HAVE_X11
            if (window && qGuiApp->nativeInterface<QNativeInterface::QX11Application>()) {
                KStartupInfo::setNewStartupId(window, qgetenv("DESKTOP_STARTUP_ID"));
            }
#endif
""")
text = text.replace("""    if (window && qGuiApp->nativeInterface<QNativeInterface::QX11Application>()) {
        KStartupInfo::setNewStartupId(window, qgetenv("DESKTOP_STARTUP_ID"));
    }
""", """#if defined(HAVE_X11) && HAVE_X11
    if (window && qGuiApp->nativeInterface<QNativeInterface::QX11Application>()) {
        KStartupInfo::setNewStartupId(window, qgetenv("DESKTOP_STARTUP_ID"));
    }
#endif
""")
path.write_text(text)
PY

python3 - "$src/shell/shellcorona.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("""void ShellCorona::clearPreviousWindow()
{
    m_previousWId = 0;
    m_previousPlasmaWindow = nullptr;
}
""", """void ShellCorona::clearPreviousWindow()
{
#if defined(HAVE_X11) && HAVE_X11
    m_previousWId = 0;
#endif
    m_previousPlasmaWindow = nullptr;
}
""")
path.write_text(text)
PY

python3 - "$src/CMakeLists.txt" <<'PY'
import re
import sys
from xios_fixlib import Path, todo

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(r"^([ \t]*)ecm_install_po_files_as_qm\(", r"\1# ios-bringup-no-linguist: ecm_install_po_files_as_qm(", text, flags=re.M)
path.write_text(text)
PY

# ---- Plasma 6.7 X11/Linux-ism guards (new since the 6.1 port; shared helper in xios_fixlib) ------------------------------
python3 - "$src" <<'PY'
import re
import sys
from xios_fixlib import Path, todo, guard_x11, guard_x11_tree

src = sys.argv[1]

# libclock: timerfd is Linux-only; upstream already ships a portable alignedtimer_posix.cpp (used for OpenBSD).
p = Path(f"{src}/libclock/CMakeLists.txt")
t = p.read_text()
t = t.replace('if(CMAKE_SYSTEM_NAME STREQUAL "OpenBSD")', 'if(CMAKE_SYSTEM_NAME STREQUAL "OpenBSD" OR APPLE)')
p.write_text(t)

# libnotificationmanager portal: the X11 startup-id branch has no KStartupInfo here.
p = Path(f"{src}/libnotificationmanager/portal_p.cpp")
t = p.read_text()
t = t.replace("#include <KStartupInfo>\n", "")
new = re.sub(r"        KStartupInfoId startupId;\n        startupId\.initId\(\);\n        activateWithPlatformData\(\{\n            \{u\"desktop-startup-id\"_s, QString::fromUtf8\(startupId\.id\(\)\)\},\n        \}\);\n",
             "        activateWithPlatformData({}); // xios: no X11 startup id\n", t)
if new == t and "KStartupInfoId" in t:
    todo("portal_p.cpp KStartupInfoId branch not found")
p.write_text(new)

# shutdowndlg: the whole X11 window-role block.
p = Path(f"{src}/logout-greeter/shutdowndlg.cpp")
t = p.read_text()
new = re.sub(r"(    if \(KWindowSystem::isPlatformX11\(\)\) \{\n        constexpr auto role.*?NET::SkipSwitcher\);\n    \}\n)",
             r"#if defined(HAVE_X11) && HAVE_X11\n\1#endif\n", t, count=1, flags=re.S)
if new == t and "constexpr auto role" in t:
    todo("shutdowndlg X11 block not found")
p.write_text(new)

# desktopview: X11 startup-id blocks and the X11-only window type.
p = Path(f"{src}/shell/desktopview.cpp")
t = p.read_text()
t = re.sub(r"( *)if \(window && qGuiApp->nativeInterface<QNativeInterface::QX11Application>\(\)\) \{\n.*?\n\1\}\n",
           lambda m: "#if defined(HAVE_X11) && HAVE_X11\n" + m.group(0) + "#endif\n", t, flags=re.S)
p.write_text(t)

# panelview: compositingActive() only exists on X11; off X11 the condition reduces to !isPlatformX11().
p = Path(f"{src}/shell/panelview.cpp")
t = p.read_text()
t = t.replace("if (!KWindowSystem::isPlatformX11() || KX11Extras::compositingActive()) {", "if (!KWindowSystem::isPlatformX11()) {")
p.write_text(t)

# libclock header: the posix timer variant is selected by the same macro the .cpp uses.
p = Path(f"{src}/libclock/alignedtimer.h")
t = p.read_text()
t = t.replace("#if defined(Q_OS_OPENBSD)", "#if defined(Q_OS_OPENBSD) || defined(Q_OS_DARWIN)")
p.write_text(t)

print("guard_x11_tree edits:", guard_x11_tree(src))
PY

# ios-perf-calendar-reset (+ios15): the digital clock's CalendarView calls
# monthView.resetToToday() on every expandedChanged, so on every popup open AND close.
# Calendar::resetToToday() then ran updateData() unconditionally, even when the
# calendar already showed today: DaysModel::update() resets the model, the month
# grid's Repeater destroys and re-creates its 42 day delegates, and every event
# plugin reloads. That was ~60% of plasmashell's main-thread time per clock popup
# open or close on the A10 (sampled 2026-10-26). setDisplayedDate() already runs
# updateData() when the date actually changes, and event plugins push their own
# updates, so the extra call only rebuilt identical data.
python3 - "$src/components/calendar/calendar.cpp" <<'PY'
import sys
from xios_fixlib import Path, todo

p = Path(sys.argv[1])
t = p.read_text()
old = """void Calendar::resetToToday()
{
    setDisplayedDate(d->today);
    updateData();
}"""
new = """void Calendar::resetToToday()
{
    // ios-perf-calendar-reset: setDisplayedDate() rebuilds the data when the date
    // changes; rebuilding when it did not re-created every day delegate for nothing.
    setDisplayedDate(d->today);
}"""
if old in t:
    p.write_text(t.replace(old, new))
else:
    todo("calendar.cpp resetToToday body not found")
PY

# ios-wallpaper-unknown-provider (+ios16): rotating the iPad while plasmashell started
# (2 of ~8 starts, 2 of 3 in a start+rotate loop) left the desktop at its old size with
# no panel and everything idle. The wallpaper is incubated asynchronously, so a
# Qt.callLater(loadImage) queued by a property change can run before MediaProxy's
# componentComplete() has classified the source; providerType is still Unknown and
# loadImage() falls back to MediaProxy::useSingleImageDefaults(). That clears m_source
# first and only then looks for the default wallpaper package, which this device does
# not have (no /usr/share/wallpapers), so it returned with the configured image gone,
# nothing ever loaded, WallpaperItem.loading stayed true, the desktop containment never
# became uiReady and ShellCorona::checkAllDesktopsUiReady() never created the waiting
# panels. Only wedged sessions log "The backend got an unknown wallpaper provider type".
# Keep the configured source when there is no default to fall back to (it is classified
# again on componentComplete), and never leave the wallpaper loading when giving up.
python3 - "$src/wallpapers/image/plugin/utils/mediaproxy.cpp" "$src/wallpapers/image/imagepackage/contents/ui/ImageStackView.qml" <<'PY'
import sys
from xios_fixlib import Path, todo

p = Path(sys.argv[1])
t = p.read_text()
old = """void MediaProxy::useSingleImageDefaults()
{
    m_source.clear(); // BUG 460692

    auto package = DefaultWallpaper::defaultWallpaperPackage();

    if (!package.isValid()) {
        return;
    }
"""
new = """void MediaProxy::useSingleImageDefaults()
{
    auto package = DefaultWallpaper::defaultWallpaperPackage();

    // ios-wallpaper-unknown-provider: without a default package there is nothing to fall
    // back to; clearing first lost a configured image that just was not classified yet.
    if (!package.isValid()) {
        return;
    }

    m_source.clear(); // BUG 460692
"""
if old in t:
    p.write_text(t.replace(old, new))
else:
    todo("mediaproxy.cpp useSingleImageDefaults head not found")

p = Path(sys.argv[2])
t = p.read_text()
old = """            mediaProxy.useSingleImageDefaults();
            return;
        }

        doesSkipAnimation"""
new = """            mediaProxy.useSingleImageDefaults();
            // ios-wallpaper-unknown-provider: still nothing to show. A wallpaper left
            // loading keeps the desktop from becoming uiReady, and with it every panel.
            if (mediaProxy.providerType == Wallpaper.Provider.Unknown) {
                wallpaperInterface.loading = false;
            }
            return;
        }

        doesSkipAnimation"""
if old in t:
    p.write_text(t.replace(old, new))
else:
    todo("ImageStackView.qml unknown-provider fallback not found")
PY

printf '%s\n' "$self_sha" > "$stamp"
