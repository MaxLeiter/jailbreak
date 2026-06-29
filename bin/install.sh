#!/usr/bin/env bash
# Build a tweak and install it to the iPad over SSH, then respring.
# Usage: bin/install.sh [tweak-dir]   (defaults to current dir)
#
# We push the .deb ourselves (scp + dpkg) instead of `make install` because
# Theos's installer can trip the SSH server's "too many auth failures" limit
# when ssh-agent offers many keys. We force a single explicit key instead.
#
# device.env (repo root, gitignored) provides:
#   THEOS_DEVICE_IP=MaxsiPad.local
#   THEOS_DEVICE_PORT=22
# Optional: SSH_KEY=~/.ssh/id_ed25519
set -euo pipefail

export THEOS="${THEOS:-$HOME/theos}"
# Prefer Homebrew's GNU Make 4.x (`gmake`) over macOS's 3.81 (`make`) so Theos
# parallelizes the build across all cores. Falls back to `make` if absent.
MAKE="$(command -v gmake || echo make)"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$REPO_ROOT/device.env" ] && { set -a; . "$REPO_ROOT/device.env"; set +a; }

IP="${THEOS_DEVICE_IP:-MaxsiPad.local}"
PORT="${THEOS_DEVICE_PORT:-22}"
KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS=(-o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -i "$KEY")

DIR="${1:-.}"
[ -f "$DIR/Makefile" ] || { echo "error: no Makefile in '$DIR'" >&2; exit 1; }
cd "$DIR"

echo "==> Building $(basename "$PWD")"
"$MAKE" package FINALPACKAGE=1
DEB="$(ls -t packages/*.deb 2>/dev/null | head -1)"
[ -n "$DEB" ] || { echo "error: no .deb produced" >&2; exit 1; }
echo "==> Built: $DEB"

echo "==> Copying to $IP:$PORT"
scp -P "$PORT" "${SSH_OPTS[@]}" "$DEB" "root@$IP:/var/jb/tmp/_install.deb"

echo "==> Installing + respringing"
ssh -p "$PORT" "${SSH_OPTS[@]}" "root@$IP" \
  'dpkg -i /var/jb/tmp/_install.deb && rm -f /var/jb/tmp/_install.deb && (nohup sbreload >/dev/null 2>&1 &) && echo "installed + respringing"'
echo "==> Done."
