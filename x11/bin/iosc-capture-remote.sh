#!/usr/bin/env bash
# Mac-side driver for bin/iosc-capture.sh.
# Ships the on-device capture helper to the iPad, runs it in the iosc session,
# and pulls back the screenshot + stderr log + printed diagnosis.
#
#   iosc-capture-remote.sh <name> <command> [args...]
#
# Examples:
#   iosc-capture-remote.sh hitori  hitori
#   iosc-capture-remote.sh zathura zathura /var/jb/tmp/doc.pdf
#   iosc-capture-remote.sh mpv     mpv-iosc /var/jb/tmp/clip.mp4
#   iosc-capture-remote.sh foot    foot --log-level=info
#
# Device target comes from the shared deploy env (device.env: THEOS_DEVICE_IP/PORT,
# default root@MaxsiPad.local:22, key ~/.ssh/id_ed25519).
# Artifacts land in ./iosc-capture-artifacts/ (override with IOSC_CAP_LOCAL).
# Exit code is passed through from the device: 0 mapped, 1 launch failure, 2 precondition.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../apps/iosc-desktop/deploy-env.sh"   # sets IP/PORT/KEY + ssh_()/scp_()

name="${1:-}"; shift || true
if [ -z "$name" ] || [ "$#" -eq 0 ]; then
    echo "usage: iosc-capture-remote.sh <name> <command> [args...]" >&2
    exit 2
fi

LOCAL="${IOSC_CAP_LOCAL:-./iosc-capture-artifacts}"
REMOTE_SH="/var/jb/tmp/iosc-capture.sh"
mkdir -p "$LOCAL"

echo "==> ship capture helper to root@$IP"
if ! scp_ "$HERE/iosc-capture.sh" "root@$IP:$REMOTE_SH"; then
    echo "ERROR: cannot reach root@$IP:$PORT (check device.env / key / that the iPad is up)" >&2
    exit 2
fi

# Quote each arg for the remote bash that runs the helper.
remote_args="$(printf ' %q' "$name" "$@")"
remote_env=()
for var in IOSC_CAP_WAIT IOSC_CAP_OUT WAYLAND_DISPLAY XDG_RUNTIME_DIR; do
    if [ "${!var+x}" = x ]; then
        remote_env+=("$var=${!var}")
    fi
done
remote_env_args="$(printf ' %q' "${remote_env[@]}")"
echo "==> run on device: iosc-capture.sh $name $*"
rc=0
ssh_ "env$remote_env_args bash $REMOTE_SH$remote_args" || rc=$?

echo "==> pull artifacts to $LOCAL"
scp_ "root@$IP:/var/jb/tmp/cap-$name.png" "$LOCAL/" 2>/dev/null \
    || echo "   (no png pulled — grim blank, -native mode, or client never mapped)"
scp_ "root@$IP:/var/jb/tmp/cap-$name.log" "$LOCAL/" 2>/dev/null \
    || echo "   (no log pulled)"
ls -l "$LOCAL"/cap-"$name".* 2>/dev/null || true

echo "==> device exit code: $rc"
exit "$rc"
