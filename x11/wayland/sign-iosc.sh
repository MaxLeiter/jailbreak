#!/usr/bin/env bash
# Host-side signer for the iosc compositor binary produced by build-iosc.sh.
#
# iOS 15+/16+ AMFI needs DER entitlements for the GPU/IOSurface/task_for_pid
# privileges used by iosc. The Mac/Homebrew ldid emits those correctly, so sign
# locally before copying the compositor to a device.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="${1:-$HERE/out/iosc}"
ENT="${2:-$HERE/iosc-gl-ent.xml}"

command -v ldid >/dev/null 2>&1 || {
  echo "ERROR: ldid not found. Install ldid on the Mac before signing iosc." >&2
  exit 1
}

[ -f "$BIN" ] || {
  echo "ERROR: missing compositor binary: $BIN" >&2
  exit 1
}

[ -f "$ENT" ] || {
  echo "ERROR: missing entitlement plist: $ENT" >&2
  exit 1
}

ldid -S"$ENT" "$BIN"

ENTS="$(ldid -e "$BIN" 2>/dev/null || true)"
for need in \
  platform-application \
  com.apple.private.skip-library-validation \
  task_for_pid-allow \
  AGXDeviceUserClient \
  IOGPUDeviceUserClient \
  IOSurfaceRootUserClient
do
  if ! grep -q "$need" <<<"$ENTS"; then
    echo "ERROR: signed binary is missing entitlement marker: $need" >&2
    exit 1
  fi
done

echo "signed: $BIN"
echo "using:  $ENT"
