#!/usr/bin/env bash
# Host-side checks for the pure parts of the Xios app (FitTransform, the touch lane
# state machine, session parsing, ioscd line formats, and the real file registry).
# No Xcode project and no XCTest: plain swiftc on the files that import no UIKit.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/xios-tests-$$"
trap 'rm -f "$OUT"' EXIT
swiftc -O -o "$OUT" \
  Sources/Core/Paths.swift \
  Sources/Core/Models.swift \
  Sources/Core/SessionParsing.swift \
  Sources/Core/IOSCDProtocol.swift \
  Sources/Core/FileWatcher.swift \
  Sources/Core/SessionRegistry.swift \
  Sources/Present/FitTransform.swift \
  Sources/Input/LaneTracker.swift \
  Tests/main.swift
"$OUT"
