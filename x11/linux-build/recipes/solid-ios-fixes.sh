#!/usr/bin/env bash
# Swaps Solid's iOS APPLE branch from the unbuildable IOKit/DiskArbitration
# backend to the QtDBus-only upower backend (IOKit/DiskArbitration headers
# don't exist in the iPhoneOS SDK), and widens the Qt6::DBus find_package
# guard, which was APPLE-excluded on the assumption APPLE meant macOS's
# IOKit backend, to include iOS too.
set -euo pipefail

src=${1:?usage: solid-ios-fixes.sh <solid-source-dir>}

python3 - "$src/CMakeLists.txt" <<'PY'
import pathlib, sys

p = pathlib.Path(sys.argv[1])
s = p.read_text()

old_dbus_guard = "if(NOT ANDROID AND NOT WIN32 AND NOT APPLE)\n    find_package(Qt6 ${REQUIRED_QT_VERSION} CONFIG REQUIRED DBus)\nendif()\n"
new_dbus_guard = (
    "# ios: the upower device backend below needs Qt6::DBus even on APPLE.\n"
    "if(NOT ANDROID AND NOT WIN32)\n"
    "    find_package(Qt6 ${REQUIRED_QT_VERSION} CONFIG REQUIRED DBus)\n"
    "endif()\n"
)
if old_dbus_guard in s:
    s = s.replace(old_dbus_guard, new_dbus_guard, 1)
elif "the upower device backend below needs Qt6::DBus even on APPLE" not in s:
    raise SystemExit("solid-ios-fixes.sh: Qt6::DBus find_package guard not found")

old_backend = "elseif (APPLE)\n    find_package(IOKit REQUIRED)\n    add_device_backend(iokit)\nelseif (WIN32)\n"
new_backend = (
    "elseif (APPLE)\n"
    "    # ios: no IOKit/DiskArbitration in the iPhoneOS SDK. xios-hwbridged\n"
    "    # (xios-fhs) owns org.freedesktop.UPower on-device, so the stock\n"
    "    # QtDBus-only upower backend works unmodified here.\n"
    "    add_device_backend(upower)\n"
    "elseif (WIN32)\n"
)
if old_backend in s:
    s = s.replace(old_backend, new_backend, 1)
elif "xios-hwbridged\n    # (xios-fhs) owns org.freedesktop.UPower" not in s:
    raise SystemExit("solid-ios-fixes.sh: elseif(APPLE) device backend block not found")

p.write_text(s)
PY
