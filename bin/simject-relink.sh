#!/bin/bash
# The substrate symlinks live on a RAM-backed tmpfs overlay that's wiped on every
# macOS reboot, so tweaks stop loading until this re-links them. Runs as root via
# LaunchDaemon (see bin/launchd/com.max.simject-relink.plist); idempotent, safe
# to fire on every volume mount.
#
# Because it runs as root, it must only ever execute root-owned code. launchd runs
# an INSTALLED copy of this file from a root:wheel directory, next to installed
# copies of simject's installsubstrate.sh and remount.sh (install steps are in the
# plist). The repo copy and ~/simject are writable by max, so running either as
# root would hand root to anything that can edit them. The check below refuses to
# run from anywhere that is not root-owned and closed to group/other writes.
set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

HERE="$(cd "$(dirname "$0")" && pwd -P)"
LOG="/Library/Logs/simject-relink.log"
exec >>"$LOG" 2>&1
echo "=== $(date '+%Y-%m-%d %H:%M:%S') simject-relink fired (uid=$(id -u)) ==="

for f in "$HERE" "$HERE/simject-relink.sh" "$HERE/installsubstrate.sh" "$HERE/remount.sh"; do
  if [ ! -e "$f" ] || [ "$(stat -f %u "$f")" != 0 ] \
     || (( (8#$(stat -f %Lp "$f") & 8#022) != 0 )); then
    echo "  refusing: $f is missing, not owned by root, or group/other-writable."
    echo "  Reinstall with the steps in bin/launchd/com.max.simject-relink.plist."
    exit 1
  fi
done

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

# installsubstrate.sh finds remount.sh through $PWD, so run it from $HERE: both
# are the installed root-owned copies.
cd "$HERE" || { echo "  cannot cd '$HERE'"; exit 1; }
echo "  running: installsubstrate.sh link"
/bin/bash ./installsubstrate.sh link
echo "  done (exit $?)"
