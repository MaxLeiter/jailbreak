#!/usr/bin/env bash
# Recovery tool: remove a tweak from the iPad and respring.
# Use this to recover when a SpringBoard tweak misbehaves (freeze / respring loop)
# — SSH keeps working even when the UI is wedged.
#
# Usage: bin/uninstall.sh <package-id>     e.g. bin/uninstall.sh com.max.helloworld
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$REPO_ROOT/device.env" ] && { set -a; . "$REPO_ROOT/device.env"; set +a; }

IP="${THEOS_DEVICE_IP:-MaxsiPad.local}"
PORT="${THEOS_DEVICE_PORT:-22}"
KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

PKG="${1:?usage: bin/uninstall.sh <package-id, e.g. com.max.helloworld>}"

echo "==> Removing $PKG from $IP and respringing"
ssh -p "$PORT" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -i "$KEY" "root@$IP" \
  "dpkg -r '$PKG' && (nohup sbreload >/dev/null 2>&1 &) && echo removed"
