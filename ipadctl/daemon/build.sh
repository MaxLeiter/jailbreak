#!/usr/bin/env bash
# Build ipadctld for arm64 iOS. Signing happens ON DEVICE (see deploy.sh):
# host-signing private entitlements with ldid is an AMFI landmine here.
#
#   ipadctl/daemon/build.sh      # -> ipadctl/daemon/build/ipadctld
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IPADCTL="$(cd "$HERE/.." && pwd)"
CORE="$IPADCTL/core"

OUT="$HERE/build"
mkdir -p "$OUT"

# The reusable native core (capture, hid, display, spi) is shared with the
# probe; the daemon adds its HTTP server, routing, app launching and logging.
xcrun -sdk iphoneos clang -arch arm64 -miphoneos-version-min=15.0 \
    -fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter \
    -I"$CORE" -I"$HERE/src" \
    -framework Foundation -framework UIKit -framework CoreGraphics \
    -framework ImageIO -framework IOSurface -framework Accelerate \
    "$CORE"/*.m "$HERE"/src/*.m -o "$OUT/ipadctld"
echo "built $OUT/ipadctld"
