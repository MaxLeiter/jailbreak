#!/usr/bin/env bash
# Host-side signer for the iosc compositor binary produced by build-iosc.sh.
#
# iOS 15+/16+ AMFI needs DER entitlements for the GPU/IOSurface/task_for_pid
# privileges used by iosc. The Mac/Homebrew ldid emits those correctly, so sign
# locally before copying the compositor to a device. Thin wrapper over xsign
# (lib/xlib.sh); the sign + entitlement-marker verification live there now.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_x="$HERE"; while [ "$_x" != / ] && [ ! -f "$_x/lib/xlib.sh" ]; do _x="$(dirname "$_x")"; done
. "$_x/lib/xlib.sh"

BIN="${1:-$HERE/out/iosc}"
ENT="${2:-$HERE/iosc-gl-ent.xml}"

[ -f "$ENT" ] || { echo "ERROR: missing entitlement plist: $ENT" >&2; exit 1; }

xsign "$BIN" "$ENT" \
  platform-application \
  com.apple.private.skip-library-validation \
  task_for_pid-allow \
  AGXDeviceUserClient \
  IOGPUDeviceUserClient \
  IOSurfaceRootUserClient
