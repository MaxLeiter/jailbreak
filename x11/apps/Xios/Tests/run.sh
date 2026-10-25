#!/usr/bin/env bash
# Host-side checks for the pure parts of the Xios app (FitTransform, the touch lane
# state machine, session parsing, ioscd line formats, the installed-preset probe
# against xios-session's own xs_preset_check, and the real file registry).
# No Xcode project and no XCTest: plain swiftc on the files that import no UIKit.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/xios-tests-$$"
trap 'rm -f "$OUT"' EXIT
# The preset probe is checked against the real xs_preset_check.
export XIOS_TEST_SESSION_LIB="$PWD/../iosc-desktop/xios-session-lib.sh"
swiftc -O -o "$OUT" \
  Sources/Core/Paths.swift \
  Sources/Core/Models.swift \
  Sources/Core/PresetAvailability.swift \
  Sources/Core/SessionParsing.swift \
  Sources/Core/IOSCDProtocol.swift \
  Sources/Core/FileWatcher.swift \
  Sources/Core/SessionRegistry.swift \
  Sources/Present/FitTransform.swift \
  Sources/Input/LaneTracker.swift \
  Tests/main.swift
"$OUT"
