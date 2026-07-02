#!/usr/bin/env bash
# Install the ioscd launch daemon to the device. Builds the binary host-side, then
# scp's it + the LaunchDaemon plist and bootstraps it. Run by the LEAD (touches the
# device); the generator + build are host-side and don't need this.
#
#   x11/apps/iosc-desktop/install-ioscd.sh
#
# device.env (repo root, gitignored) provides THEOS_DEVICE_IP / THEOS_DEVICE_PORT.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/deploy-env.sh"   # IP/PORT/SSH_OPTS + ssh_/scp_ (loads device.env)

[ -x "$HERE/out/ioscd" ] || bash "$HERE/build-stub.sh"

echo "==> copy ioscd -> /var/jb/usr/local/bin"
scp_ "$HERE/out/ioscd" "root@$IP:/var/jb/usr/local/bin/ioscd"
ssh_ "chmod 0755 /var/jb/usr/local/bin/ioscd"

echo "==> install LaunchDaemon + (re)bootstrap"
scp_ "$HERE/com.max.ioscd.plist" \
    "root@$IP:/var/jb/Library/LaunchDaemons/com.max.ioscd.plist"
ssh_ "chown root:wheel /var/jb/Library/LaunchDaemons/com.max.ioscd.plist; \
      chmod 0644 /var/jb/Library/LaunchDaemons/com.max.ioscd.plist; \
      launchctl bootout system /var/jb/Library/LaunchDaemons/com.max.ioscd.plist 2>/dev/null; \
      launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.max.ioscd.plist; \
      sleep 1; ls -l /var/jb/tmp/ioscd.sock 2>&1; \
      echo '--- ioscd.log ---'; tail -5 /var/jb/tmp/ioscd.log 2>/dev/null"
echo "==> ioscd installed. Control socket should be /var/jb/tmp/ioscd.sock"
