#!/bin/bash
# simject-relink.sh — restore simject's substrate symlinks in the iOS Simulator
# runtimes after a reboot.
#
# WHY: the symlinks (CydiaSubstrate.framework + MobileSubstrate/DynamicLibraries)
# live on a RAM-backed tmpfs overlay that installsubstrate.sh mounts over each
# sealed, read-only runtime's Library. tmpfs is wiped on every macOS reboot, so
# the simulator loses substrate and tweaks stop loading. This re-runs
# `installsubstrate.sh link` to recreate them.
#
# Run by a LaunchDaemon as ROOT (link mounts tmpfs + writes into system paths).
# See bin/launchd/com.max.simject-relink.plist for install instructions.
#
# Idempotent + cheap: remount.sh skips the overlay if it's already mounted, and
# the symlink step is just rm -rf + ln -s. Safe to fire on every volume mount.
set -u

LOG="/Users/max/Library/Logs/simject-relink.log"
SIMJECT_DIR="/Users/max/simject"
exec >>"$LOG" 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') simject-relink fired (uid=$(id -u)) ==="

# Nothing to do unless simject's substrate framework was built (./installsubstrate.sh subst).
if [ ! -e /opt/simject/Frameworks/CydiaSubstrate.framework/CydiaSubstrate ]; then
  echo "  CydiaSubstrate.framework missing — run 'installsubstrate.sh subst' first. Skipping."
  exit 0
fi

# The runtime volumes mount at boot OR lazily when Simulator launches. If none are
# mounted yet, bail quietly — StartOnMount re-fires this when they appear.
if ! ls -d /Library/Developer/CoreSimulator/Volumes/iOS_* >/dev/null 2>&1; then
  echo "  no iOS_* runtime volumes mounted yet — skipping (will re-fire on mount)."
  exit 0
fi

cd "$SIMJECT_DIR" || { echo "  cannot cd '$SIMJECT_DIR'"; exit 1; }
echo "  running: ./installsubstrate.sh link"
./installsubstrate.sh link
echo "  done (exit $?)"
