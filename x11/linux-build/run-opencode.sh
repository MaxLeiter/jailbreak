#!/usr/bin/env bash
# Mac-side runner for the reproducible OpenCode iOS bring-up/package path.
set -euo pipefail
cd "$(dirname "$0")"

# The package gate is deliberate: current upstream macOS Bun standalone
# payloads start on iOS after Mach-O patching but still SIGILL on the A10.
# Keep PACKAGE=0 by default so we cannot publish a broken `opencode`.
SMOKE_DEVICE="${SMOKE_DEVICE:-1}" PACKAGE="${PACKAGE:-0}" ./build-opencode.sh "$@"
