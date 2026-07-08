#!/usr/bin/env bash
# solid-ios-fixes.sh — swap Solid's iOS device backend from the unbuildable
# IOKit/DiskArbitration backend to the plain-QtDBus upower backend.
#
# Audited against v6.3.0's top-level CMakeLists.txt. Two independent guards
# need widening (both keyed on `elseif (APPLE)` / `AND NOT APPLE`, same
# pattern kguiaddons/kidletime/kio got elsewhere in this table):
#
#   1. The device backend chain's `elseif (APPLE)` branch calls
#      find_package(IOKit REQUIRED) + add_device_backend(iokit). IOKit and
#      DiskArbitration headers/frameworks do not exist in the iPhoneOS SDK, so
#      this branch can never build for iOS. Solid also ships a upower backend
#      (src/solid/devices/backends/upower) that is pure QtDBus talking to
#      org.freedesktop.UPower - no udev/sysfs/Q_OS-specific code at all - and
#      is already used unmodified by the generic 'elseif (NOT ANDROID)' Unix
#      branch below it. xios-fhs's xios-hwbridged daemon owns
#      org.freedesktop.UPower on-device (backed by real IOKit power sources),
#      so the iOS branch is swapped to add_device_backend(upower) instead.
#   2. The upower backend links Qt6::DBus (conditionally: `if (TARGET
#      Qt6::DBus)` in src/solid/CMakeLists.txt), but the top-level
#      find_package(Qt6 ... DBus) call is itself guarded
#      `if(NOT ANDROID AND NOT WIN32 AND NOT APPLE)` with the comment
#      "Windows & Mac have backends that don't use DBus" - true while APPLE
#      meant macOS's IOKit backend, no longer true now that APPLE means iOS on
#      the upower backend. That guard is widened to drop APPLE so Qt6::DBus
#      actually gets found and linked.
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
