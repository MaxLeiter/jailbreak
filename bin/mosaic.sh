#!/usr/bin/env bash
# Deploy Mosaic (the macOS-style window-manager tweak + its Settings pane) and set it on/off.
#   bin/mosaic.sh on    # install + enable
#   bin/mosaic.sh off   # install + disable (dormant: no chrome, normal iPad)
# Device override: MOSAIC_DEV=root@host bin/mosaic.sh off
set -euo pipefail

STATE="${1:-on}"
DEV="${MOSAIC_DEV:-root@MaxsiPad.local}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

TW=$(ls -t "$ROOT"/tweaks/_research/carplayhost/packages/com.max.carplayhost_0.1.0_*.deb | head -1)
PR=$(ls -t "$ROOT"/tweaks/_research/mosaicprefs/packages/com.max.mosaicprefs_*.deb | head -1)
[ "$STATE" = off ] && EN=false || EN=true

echo "→ Mosaic: copying packages to $DEV…"
scp "$TW" "$PR" "$DEV:/tmp/"

echo "→ installing + setting enabled=$EN + respringing…"
ssh "$DEV" "
  set -e
  dpkg -i '/tmp/$(basename "$TW")' '/tmp/$(basename "$PR")'
  printf '%s' '<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>enabled</key><$EN/></dict></plist>' \
    > /var/mobile/Library/Preferences/com.max.mosaic.plist
  chown mobile:mobile /var/mobile/Library/Preferences/com.max.mosaic.plist || true
  killall -9 cfprefsd 2>/dev/null || true
  sbreload 2>/dev/null || killall -9 SpringBoard 2>/dev/null || true
"
echo "✓ Mosaic deployed ($STATE)."
