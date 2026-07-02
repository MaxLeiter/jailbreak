#!/usr/bin/env bash
# Install the Xios session launcher to the device WITHOUT building a deb — scp the
# scripts + plist and bootstrap the daemon. Run by the LEAD (touches the device);
# handy for iterating faster than package-session.sh -> Sileo. For a shippable
# artifact use package-session.sh instead.
#
#   x11/apps/iosc-desktop/install-xios-session.sh
#
# device.env (repo root, gitignored) provides THEOS_DEVICE_IP / THEOS_DEVICE_PORT.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
WAYLAND="$REPO_ROOT/x11/wayland"
SHELLDIR="$REPO_ROOT/x11/apps/iosc-shell"
[ -f "$REPO_ROOT/device.env" ] && { set -a; . "$REPO_ROOT/device.env"; set +a; }
IP="${THEOS_DEVICE_IP:-MaxsiPad.local}"; PORT="${THEOS_DEVICE_PORT:-22}"
KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS=(-o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -i "$KEY")
ssh_() { ssh -p "$PORT" "${SSH_OPTS[@]}" "root@$IP" "$@"; }
scp_() { scp -P "$PORT" "${SSH_OPTS[@]}" "$@"; }

LIBEXEC=/var/jb/libexec/xios-session

echo "==> mkdir on-device dirs"
ssh_ "mkdir -p $LIBEXEC /var/jb/usr/local/bin /var/jb/Library/LaunchDaemons"

echo "==> copy CLI + library + daemon"
scp_ "$HERE/xios-session"           "root@$IP:/var/jb/usr/local/bin/xios-session"
scp_ "$HERE/xios-session-lib.sh"    "root@$IP:$LIBEXEC/xios-session-lib.sh"
scp_ "$HERE/xios-sessiond"          "root@$IP:$LIBEXEC/xios-sessiond"

echo "==> copy the reused bring-up scripts"
scp_ "$SHELLDIR/run-shell.sh"       "root@$IP:$LIBEXEC/run-shell.sh"
scp_ "$WAYLAND/run-mutter.sh"       "root@$IP:$LIBEXEC/run-mutter.sh"
scp_ "$WAYLAND/run-gnome-shell.sh"  "root@$IP:$LIBEXEC/run-gnome-shell.sh"

echo "==> copy LaunchDaemon plist"
scp_ "$HERE/com.max.xios-sessiond.plist" \
     "root@$IP:/var/jb/Library/LaunchDaemons/com.max.xios-sessiond.plist"

echo "==> perms + (re)bootstrap the watcher daemon"
ssh_ "chmod 0755 /var/jb/usr/local/bin/xios-session $LIBEXEC/xios-sessiond $LIBEXEC/run-*.sh; \
      chmod 0644 $LIBEXEC/xios-session-lib.sh; \
      chown root:wheel /var/jb/Library/LaunchDaemons/com.max.xios-sessiond.plist; \
      chmod 0644 /var/jb/Library/LaunchDaemons/com.max.xios-sessiond.plist; \
      launchctl bootout system /var/jb/Library/LaunchDaemons/com.max.xios-sessiond.plist 2>/dev/null; \
      launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.max.xios-sessiond.plist; \
      sleep 1; echo '--- xios-sessiond.log ---'; tail -5 /var/jb/tmp/xios-sessiond.log 2>/dev/null"

echo "==> installed. From an SSH shell or the terminal on-device:"
echo "      xios-session iosc | mutter | gnome | app kgx | stop | status"
echo "    In-app picker writes /var/jb/tmp/xios-request.json (action=session); the daemon serves it."
