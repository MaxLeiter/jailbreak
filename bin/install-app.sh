#!/usr/bin/env bash
# Build the KitchenHub iOS app and install it to the jailbroken iPad over SSH.
# This is the app-bundle counterpart to bin/install.sh (which installs .deb tweaks).
#
# Mac needs:    Xcode, xcodegen, ldid          (all via brew except Xcode)
# iPad needs:   rootless jailbreak + AppSync Unified (to run the unsigned app)
#               and uicache at /var/jb/usr/bin/uicache (standard on palera1n).
#
# device.env (repo root, gitignored) provides THEOS_DEVICE_IP / THEOS_DEVICE_PORT.
# Usage: bin/install-app.sh [app-dir]   (defaults to apps/KitchenHub)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${1:-$REPO_ROOT/apps/KitchenHub}"
# Canonicalize to an absolute path: the script `cd`s into APP_DIR later but still
# references "$APP_DIR/entitlements.plist", so a relative arg would resolve wrong
# (and silently skip entitlements -> e.g. a black screen from the GPU sandbox).
APP_DIR="$(cd "$APP_DIR" 2>/dev/null && pwd)" || { echo "error: app dir not found: ${1}" >&2; exit 1; }
[ -f "$REPO_ROOT/device.env" ] && { set -a; . "$REPO_ROOT/device.env"; set +a; }

IP="${THEOS_DEVICE_IP:-MaxsiPad.local}"
PORT="${THEOS_DEVICE_PORT:-22}"
KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS=(-o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -i "$KEY")

# Derive app name/bundle id from the target dir + its project.yml (works for any app).
APP_NAME="$(basename "$APP_DIR")"
BUNDLE_ID="$(grep -E 'PRODUCT_BUNDLE_IDENTIFIER' "$APP_DIR/project.yml" 2>/dev/null | head -1 | sed 's/.*: *//' | tr -d '"' || true)"
[ -n "$BUNDLE_ID" ] || BUNDLE_ID="com.max.$(echo "$APP_NAME" | tr 'A-Z' 'a-z')"
DEST="/var/jb/Applications/${APP_NAME}.app"

# Build + pseudo-sign via the shared helper (same path bin/package-app.sh uses).
. "$REPO_ROOT/bin/lib/build-app.sh"
APP="$(build_app "$APP_DIR")"

echo "==> Installing to $IP:$DEST"
ssh -p "$PORT" "${SSH_OPTS[@]}" "root@$IP" "rm -rf '$DEST'"
scp -P "$PORT" "${SSH_OPTS[@]}" -r "$APP" "root@$IP:/var/jb/Applications/"
ssh -p "$PORT" "${SSH_OPTS[@]}" "root@$IP" \
  "chmod -R 0755 '$DEST'; /var/jb/usr/bin/uicache -p '$DEST' && echo 'registered $BUNDLE_ID'"

echo "==> Done. Look for ${APP_NAME} on the Home Screen."
