#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
X11_ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${OUT:-$X11_ROOT/linux-build/out}"
EPIPHANY_VERSION="${EPIPHANY_VERSION:-43.1+ios2}"

APP_DEB="$(find "$OUT" -maxdepth 1 -type f \
  -name "epiphany_${EPIPHANY_VERSION}_iphoneos-arm64.deb" | head -1)"
[ -n "$APP_DEB" ] || {
  echo "error: epiphany $EPIPHANY_VERSION deb is missing from $OUT" >&2
  exit 2
}

exec "$X11_ROOT/apps/iosc-desktop/package-native-app.sh" \
  --app-deb "$APP_DEB" \
  --desktop org.gnome.Epiphany.desktop \
  --package epiphany-native \
  --version "$EPIPHANY_VERSION" \
  --depends "epiphany (= $EPIPHANY_VERSION), xios-launcher-tools (>= 0.1.3), iosc (>= 0.9.38)" \
  --bundle-name "Web" \
  --bundle-basename "Web" \
  --description "native iPadOS multi-window host app for GNOME Web" \
  --out "$OUT"
