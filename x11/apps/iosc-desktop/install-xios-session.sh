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
. "$HERE/deploy-env.sh"       # IP/PORT/SSH_OPTS + ssh_/scp_ (loads device.env)
. "$HERE/session-files.sh"    # session_manifest — the ONE ship-manifest, shared
                              # with package-session.sh so deb and scp can't diverge

echo "==> mkdir on-device dirs"
DEST_DIRS="$(session_manifest | awk -F'\t' '{ sub("/[^/]*$", "", $2); print "/var/jb/" $2 }' | sort -u | tr '\n' ' ')"
ssh_ "mkdir -p $DEST_DIRS"

echo "==> copy the ship manifest (CLI + lib + daemon + bring-up scripts + plist)"
while IFS=$'\t' read -r src dst mode; do
  scp_ "$src" "root@$IP:/var/jb/$dst"
done < <(session_manifest)

echo "==> perms + (re)bootstrap the watcher daemon"
CHMODS="$(session_manifest | awk -F'\t' '{ printf "chmod %s /var/jb/%s; ", $3, $2 }')"
ssh_ "$CHMODS \
      chown root:wheel /var/jb/Library/LaunchDaemons/com.max.xios-sessiond.plist; \
      launchctl bootout system /var/jb/Library/LaunchDaemons/com.max.xios-sessiond.plist 2>/dev/null; \
      launchctl bootstrap system /var/jb/Library/LaunchDaemons/com.max.xios-sessiond.plist; \
      sleep 1; echo '--- xios-sessiond.log ---'; tail -5 /var/jb/tmp/xios-sessiond.log 2>/dev/null"

echo "==> installed. From an SSH shell or the terminal on-device:"
echo "      xios-session iosc | mutter | gnome | app kgx | stop | status"
echo "    In-app picker prefers /var/jb/tmp/ioscd.sock SESSION; xios-sessiond keeps the request-file fallback."
