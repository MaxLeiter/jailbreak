#!/usr/bin/env bash
# Build ipadctl-probe for arm64 iOS, optionally deploy it and sign ON DEVICE.
#
#   ipadctl/probe/build.sh            # build -> ipadctl/probe/build/ipadctl-probe
#   ipadctl/probe/build.sh --deploy   # build, scp binary + ents.plist, ldid -S on the iPad
#
# Host-signing private entitlements with ldid is unreliable on this device
# (AMFI SIGKILLs the binary before main, exit 137, no output), so the binary
# is signed by the iPad's own ldid. Install dir: /var/jb/var/root/ipadctl/.
# ENTS=path/to/other.plist overrides the entitlements (used for ablation).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IPADCTL="$(cd "$HERE/.." && pwd)"
CORE="$IPADCTL/core"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
[ -f "$REPO_ROOT/device.env" ] && { set -a; . "$REPO_ROOT/device.env"; set +a; }

HOST="${THEOS_DEVICE_IP:-MaxsiPad.local}"
PORT="${THEOS_DEVICE_PORT:-22}"
KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
COMMON=(-o IdentitiesOnly=yes -o ConnectTimeout=10 -i "$KEY")
DEST=/var/jb/var/root/ipadctl
ENTS="${ENTS:-$HERE/ents.plist}"

OUT="$HERE/build"
mkdir -p "$OUT"

# The reusable native core (capture, hid, display, spi) lives in ipadctl/core
# and is shared with the daemon; the probe adds only its own CLI front end.
xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
    -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter \
    -I"$CORE" \
    -framework Foundation -framework UIKit -framework CoreGraphics \
    -framework ImageIO -framework IOSurface -framework Accelerate \
    "$CORE"/*.m "$HERE"/src/*.m -o "$OUT/ipadctl-probe"
echo "built $OUT/ipadctl-probe"

if [ "${1:-}" = "--deploy" ]; then
    ssh -p "$PORT" "${COMMON[@]}" "root@$HOST" "mkdir -p $DEST"
    scp -P "$PORT" "${COMMON[@]}" "$OUT/ipadctl-probe" "root@$HOST:$DEST/ipadctl-probe.new"
    scp -P "$PORT" "${COMMON[@]}" "$ENTS" "root@$HOST:$DEST/ents.plist"
    ssh -p "$PORT" "${COMMON[@]}" "root@$HOST" \
        "cd $DEST && ldid -Sents.plist ipadctl-probe.new && chmod 755 ipadctl-probe.new && mv -f ipadctl-probe.new ipadctl-probe && ldid -e ipadctl-probe | grep -c '<key>' | sed 's/^/entitlement keys: /'"
    echo "deployed to $HOST:$DEST/ipadctl-probe (signed on device)"
fi
