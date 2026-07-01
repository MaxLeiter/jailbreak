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
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
[ -f "$REPO_ROOT/device.env" ] && { set -a; . "$REPO_ROOT/device.env"; set +a; }
IP="${THEOS_DEVICE_IP:-MaxsiPad.local}"; PORT="${THEOS_DEVICE_PORT:-22}"
KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS=(-o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -i "$KEY")
ssh_() { ssh -p "$PORT" "${SSH_OPTS[@]}" "root@$IP" "$@"; }

[ -x "$HERE/out/ioscd" ] || bash "$HERE/build-stub.sh"

echo "==> copy ioscd -> /var/jb/usr/local/bin"
scp -P "$PORT" "${SSH_OPTS[@]}" "$HERE/out/ioscd" "root@$IP:/var/jb/usr/local/bin/ioscd"
ssh_ "chmod 0755 /var/jb/usr/local/bin/ioscd"

echo "==> install LaunchDaemon + (re)bootstrap"
scp -P "$PORT" "${SSH_OPTS[@]}" "$HERE/com.max.ioscd.plist" \
    "root@$IP:/var/jb/Library/LaunchDaemons/com.max.ioscd.plist"
ssh_ "chown root:wheel /var/jb/Library/LaunchDaemons/com.max.ioscd.plist; \
      chmod 0644 /var/jb/Library/LaunchDaemons/com.max.ioscd.plist; \
      launchctl bootout system /var/jb/Library/LaunchDaemons/com.max.ioscd.plist 2>/dev/null; \
      launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.max.ioscd.plist; \
      sleep 1; ls -l /var/jb/tmp/ioscd.sock 2>&1; \
      echo '--- ioscd.log ---'; tail -5 /var/jb/tmp/ioscd.log 2>/dev/null"
echo "==> ioscd installed. Control socket should be /var/jb/tmp/ioscd.sock"
