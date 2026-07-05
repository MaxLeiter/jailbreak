#!/usr/bin/env bash
# libkscreen-ios-fixes.sh - Wayland-only libkscreen build fixes for rootless iOS.
set -euo pipefail

src=${1:?usage: libkscreen-ios-fixes.sh <libkscreen-source-dir>}

python3 - "$src/src/libdpms/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
original = """add_library(KF6ScreenDpms SHARED)
target_sources(KF6ScreenDpms PRIVATE dpms.cpp abstractdpmshelper.cpp waylanddpmshelper.cpp xcbdpmshelper.cpp waylanddpmshelper.cpp)
target_link_libraries(KF6ScreenDpms PUBLIC Qt::Gui
                                    PRIVATE XCB::XCB XCB::DPMS XCB::RANDR
                                            Qt::GuiPrivate Qt::WaylandClient Wayland::Client
)
"""
previous = """add_library(KF6ScreenDpms SHARED)
set(kscreen_dpms_SRCS
    dpms.cpp
    abstractdpmshelper.cpp
    waylanddpmshelper.cpp
)
if(NOT APPLE)
    list(APPEND kscreen_dpms_SRCS xcbdpmshelper.cpp)
endif()
target_sources(KF6ScreenDpms PRIVATE ${kscreen_dpms_SRCS})
target_link_libraries(KF6ScreenDpms PUBLIC Qt::Gui
                                    PRIVATE Qt::WaylandClient Wayland::Client
)
if(NOT APPLE)
    target_link_libraries(KF6ScreenDpms PRIVATE XCB::XCB XCB::DPMS XCB::RANDR Qt::GuiPrivate)
endif()
"""
new = """add_library(KF6ScreenDpms SHARED)
set(kscreen_dpms_SRCS
    dpms.cpp
    abstractdpmshelper.cpp
)
if(NOT APPLE)
    list(APPEND kscreen_dpms_SRCS waylanddpmshelper.cpp xcbdpmshelper.cpp)
endif()
target_sources(KF6ScreenDpms PRIVATE ${kscreen_dpms_SRCS})
target_link_libraries(KF6ScreenDpms PUBLIC Qt::Gui)
if(NOT APPLE)
    target_link_libraries(KF6ScreenDpms PRIVATE
        XCB::XCB XCB::DPMS XCB::RANDR
        Qt::GuiPrivate Qt::WaylandClient Wayland::Client
    )
endif()
"""
if new not in text:
    if original in text:
        text = text.replace(original, new)
    elif previous in text:
        text = text.replace(previous, new)
    else:
        raise SystemExit("libdpms CMake XCB block not found")
wayland_protocol = "qt6_generate_wayland_protocol_client_sources(KF6ScreenDpms FILES ${PLASMA_WAYLAND_PROTOCOLS_DIR}/dpms.xml)"
guarded_wayland_protocol = f"if(NOT APPLE)\n    {wayland_protocol}\nendif()"
if guarded_wayland_protocol not in text:
    text = text.replace(wayland_protocol, guarded_wayland_protocol)
path.write_text(text)
PY

python3 - "$src/src/libdpms/dpms.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
if '#include "abstractdpmshelper_p.h"\n' not in text:
    text = text.replace('#include "kscreendpms_debug.h"\n', '#include "kscreendpms_debug.h"\n#include "abstractdpmshelper_p.h"\n')
guarded_helpers = '#if !defined(__APPLE__)\n#include "waylanddpmshelper_p.h"\n#include "xcbdpmshelper_p.h"\n#endif\n'
if guarded_helpers not in text:
    text = text.replace(
        '#include "waylanddpmshelper_p.h"\n#if !defined(__APPLE__)\n#include "xcbdpmshelper_p.h"\n#endif\n',
        guarded_helpers,
    )
if guarded_helpers not in text:
    text = text.replace(
        '#include "waylanddpmshelper_p.h"\n#include "xcbdpmshelper_p.h"\n',
        guarded_helpers,
    )
if guarded_helpers not in text:
    raise SystemExit("dpms helper include block not found")
if "#if !defined(__APPLE__)\n#include <QtGui/private/qtx11extras_p.h>\n#endif\n" not in text:
    text = text.replace("#include <QtGui/private/qtx11extras_p.h>\n", "#if !defined(__APPLE__)\n#include <QtGui/private/qtx11extras_p.h>\n#endif\n")
original = """    if (QX11Info::isPlatformX11()) {
        m_helper.reset(new XcbDpmsHelper);
    } else if (QGuiApplication::platformName().startsWith(QLatin1String("wayland"), Qt::CaseInsensitive)) {
        m_helper.reset(new WaylandDpmsHelper);
    } else {
"""
previous = """#if !defined(__APPLE__)
    if (QX11Info::isPlatformX11()) {
        m_helper.reset(new XcbDpmsHelper);
    } else
#endif
    if (QGuiApplication::platformName().startsWith(QLatin1String("wayland"), Qt::CaseInsensitive)) {
        m_helper.reset(new WaylandDpmsHelper);
    } else {
"""
new = """#if defined(__APPLE__)
    qCWarning(KSCREEN_DPMS) << "dpms unsupported on this system";
    return;
#else
    if (QX11Info::isPlatformX11()) {
        m_helper.reset(new XcbDpmsHelper);
    } else if (QGuiApplication::platformName().startsWith(QLatin1String("wayland"), Qt::CaseInsensitive)) {
        m_helper.reset(new WaylandDpmsHelper);
    } else {
"""
if new not in text:
    if original in text:
        text = text.replace(original, new)
    elif previous in text:
        text = text.replace(previous, new)
    else:
        raise SystemExit("dpms backend selection block not found")
end_block = """        qCWarning(KSCREEN_DPMS) << "dpms unsupported on this system";
        return;
    }

    connect(m_helper.data(), &AbstractDpmsHelper::supportedChanged, this, &Dpms::supportedChanged);
"""
if "#endif\n\n    connect(m_helper.data(), &AbstractDpmsHelper::supportedChanged" not in text:
    text = text.replace(
        end_block,
        """        qCWarning(KSCREEN_DPMS) << "dpms unsupported on this system";
        return;
    }
#endif

    connect(m_helper.data(), &AbstractDpmsHelper::supportedChanged, this, &Dpms::supportedChanged);
""",
    )
trigger_call = "    m_helper->trigger(mode, screens.isEmpty() ? qGuiApp->screens() : screens);\n"
guarded_trigger = (
    "    if (m_helper.isNull()) {\n"
    "        return;\n"
    "    }\n"
    f"{trigger_call}"
)
text = text.replace(guarded_trigger + guarded_trigger[len("    if (m_helper.isNull()) {\n        return;\n    }\n"):], guarded_trigger)
if guarded_trigger not in text:
    text = text.replace(trigger_call, guarded_trigger)
text = text.replace("    return m_helper->isSupported();\n", "    return !m_helper.isNull() && m_helper->isSupported();\n")
text = text.replace("    return m_helper->hasPendingChanges();\n", "    return !m_helper.isNull() && m_helper->hasPendingChanges();\n")
path.write_text(text)
PY

python3 - "$src/src/backendmanager.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
if "#if !defined(__APPLE__)\n#include <QtGui/private/qtx11extras_p.h>\n#endif\n" not in text:
    text = text.replace("#include <QtGui/private/qtx11extras_p.h>\n", "#if !defined(__APPLE__)\n#include <QtGui/private/qtx11extras_p.h>\n#endif\n")
old = """        if (QX11Info::isPlatformX11()) {
            backendFilter = QStringLiteral("XRandR");
        } else if (QGuiApplication::platformName().startsWith(QLatin1String("wayland"))) {
            backendFilter = QStringLiteral("KWayland");
        } else {
            backendFilter = QStringLiteral("QScreen");
        }
"""
new = """#if !defined(__APPLE__)
        if (QX11Info::isPlatformX11()) {
            backendFilter = QStringLiteral("XRandR");
        } else
#endif
        if (QGuiApplication::platformName().startsWith(QLatin1String("wayland"))) {
            backendFilter = QStringLiteral("KWayland");
        } else {
            backendFilter = QStringLiteral("QScreen");
        }
"""
if old not in text:
    if "#if !defined(__APPLE__)\n        if (QX11Info::isPlatformX11())" not in text:
        raise SystemExit("preferred backend selection block not found")
else:
    text = text.replace(old, new)
path.write_text(text)
PY

python3 - "$src/src/libdpms/waylanddpmshelper.cpp" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace("#include <qpa/qplatformscreen_p.h>\n", "")
path.write_text(text)
PY

python3 - "$src/CMakeLists.txt" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    "find_package(Qt6 ${QT_MIN_VERSION} CONFIG REQUIRED Core DBus Gui Test WaylandClient)",
    "find_package(Qt6 ${QT_MIN_VERSION} CONFIG REQUIRED Core DBus Gui WaylandClient)",
)
text = text.replace("ecm_install_po_files_as_qm(poqm)", "# ios-bringup-no-linguist: ecm_install_po_files_as_qm(poqm)")
path.write_text(text)
PY
