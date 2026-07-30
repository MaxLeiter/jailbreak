#!/usr/bin/env bash
# Install the ioscd launch daemon to the device. Builds the binary host-side, then
# scp's it + the LaunchDaemon plist and bootstraps it. Run by the LEAD (touches the
# device); the generator + build are host-side and don't need this.
#
#   x11/apps/iosc-desktop/install-ioscd.sh
#
# device.env (repo root, gitignored) provides THEOS_DEVICE_IP / THEOS_DEVICE_PORT.
set -euo pipefail
_xt="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ "$_xt" != / ] && [ ! -f "$_xt/linux-build/target-lib.sh" ]; do _xt="$(dirname "$_xt")"; done
. "$_xt/linux-build/target-lib.sh"
xios_load_target "${XIOS_TARGET:-rootless-1900}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/deploy-env.sh"   # IP/PORT/SSH_OPTS + ssh_/scp_ (loads device.env)

[ -x "$HERE/out/ioscd" ] || bash "$HERE/build-stub.sh"

echo "==> copy ioscd -> $XIOS_PREFIX/usr/local/bin"
scp_ "$HERE/out/ioscd" "root@$IP:$XIOS_PREFIX/usr/local/bin/ioscd"
scp_ "$HERE/xios-start-a11y" "root@$IP:$XIOS_PREFIX/usr/local/bin/xios-start-a11y"
ssh_ "chmod 0755 $XIOS_PREFIX/usr/local/bin/ioscd $XIOS_PREFIX/usr/local/bin/xios-start-a11y"

echo "==> install LaunchDaemon + (re)bootstrap"
scp_ "$HERE/com.max.ioscd.plist" \
    "root@$IP:$XIOS_PREFIX/Library/LaunchDaemons/com.max.ioscd.plist"
ssh_ "chown root:wheel $XIOS_PREFIX/Library/LaunchDaemons/com.max.ioscd.plist; \
      chmod 0644 $XIOS_PREFIX/Library/LaunchDaemons/com.max.ioscd.plist; \
      launchctl bootout system $XIOS_PREFIX/Library/LaunchDaemons/com.max.ioscd.plist 2>/dev/null; \
      launchctl bootstrap system $XIOS_PREFIX/Library/LaunchDaemons/com.max.ioscd.plist; \
      sleep 1; ls -l $XIOS_PREFIX/tmp/ioscd.sock 2>&1; \
      echo '--- ioscd.log ---'; tail -5 $XIOS_PREFIX/tmp/ioscd.log 2>/dev/null"
echo "==> ioscd installed. Control socket should be $XIOS_PREFIX/tmp/ioscd.sock"
