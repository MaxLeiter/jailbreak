#!/usr/bin/env bash
# Mac-side runner for the reproducible Bun iPhoneOS/A10 source-build path.
set -euo pipefail
cd "$(dirname "$0")"
./build-bun-ios.sh "$@"
