#!/usr/bin/env bash
# Install the Xios session launcher to the device WITHOUT building a deb — scp the
# scripts. Run by the LEAD (touches the device);
# handy for iterating faster than package-session.sh -> Sileo. For a shippable
# artifact use package-session.sh instead.
#
#   x11/apps/iosc-desktop/install-xios-session.sh
#
# device.env (repo root, gitignored) provides THEOS_DEVICE_IP / THEOS_DEVICE_PORT.
set -euo pipefail
_xt="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ "$_xt" != / ] && [ ! -f "$_xt/linux-build/target-lib.sh" ]; do _xt="$(dirname "$_xt")"; done
. "$_xt/linux-build/target-lib.sh"
xios_load_target "${XIOS_TARGET:-rootless-1900}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/deploy-env.sh"       # IP/PORT/SSH_OPTS + ssh_/scp_ (loads device.env)
. "$HERE/session-files.sh"    # session_manifest — the ONE ship-manifest, shared
                              # with package-session.sh so deb and scp can't diverge

echo "==> mkdir on-device dirs"
DEST_DIRS="$(session_manifest | awk -F'\t' '{ sub("/[^/]*$", "", $2); print "$XIOS_PREFIX/" $2 }' | sort -u | tr '\n' ' ')"
ssh_ "mkdir -p $DEST_DIRS"

echo "==> copy the ship manifest (CLI + lib + bring-up scripts)"
while IFS=$'\t' read -r src dst mode; do
  scp_ "$src" "root@$IP:$XIOS_PREFIX/$dst"
done < <(session_manifest)

echo "==> perms"
CHMODS="$(session_manifest | awk -F'\t' '{ printf "chmod %s $XIOS_PREFIX/%s; ", $3, $2 }')"
ssh_ "$CHMODS"

echo "==> installed. From an SSH shell or the terminal on-device:"
echo "      xios-session iosc | mutter | gnome | app kgx | stop | status"
echo "    In-app picker requires $XIOS_PREFIX/tmp/ioscd.sock SESSION."
