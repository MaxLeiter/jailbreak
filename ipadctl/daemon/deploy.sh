#!/usr/bin/env bash
# Build, deploy, sign-on-device and control ipadctld.
#
#   ipadctl/daemon/deploy.sh deploy    # build, scp, ldid -S on device, reload
#   ipadctl/daemon/deploy.sh start     # launchctl load
#   ipadctl/daemon/deploy.sh stop      # launchctl unload
#   ipadctl/daemon/deploy.sh status    # is it loaded? recent log
#   ipadctl/daemon/deploy.sh token     # print the bearer token (for IPADCTL_TOKEN)
#
# The daemon is loaded explicitly and is NOT installed into
# /var/jb/Library/LaunchDaemons, so it does not auto-start at boot.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
[ -f "$REPO_ROOT/device.env" ] && { set -a; . "$REPO_ROOT/device.env"; set +a; }

HOST="${THEOS_DEVICE_IP:-MaxsiPad.local}"
PORT="${THEOS_DEVICE_PORT:-22}"
KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH=(ssh -p "$PORT" -o IdentitiesOnly=yes -o ConnectTimeout=10 -i "$KEY" "root@$HOST")
SCP=(scp -P "$PORT" -o IdentitiesOnly=yes -o ConnectTimeout=10 -i "$KEY")

DEST=/var/jb/var/root/ipadctl
PLIST="$DEST/com.max.ipadctld.plist"
LABEL=com.max.ipadctld

do_build() { "$HERE/build.sh"; }

do_stop() {
    # Unload if currently loaded; ignore "not loaded".
    "${SSH[@]}" "launchctl unload '$PLIST' 2>/dev/null || launchctl bootout system/$LABEL 2>/dev/null || true; echo stopped"
}

do_start() {
    "${SSH[@]}" "launchctl load '$PLIST' 2>/dev/null || launchctl bootstrap system '$PLIST' 2>/dev/null || true; sleep 1; launchctl list | awk '/$LABEL/{print}'"
}

do_deploy() {
    do_build
    "${SSH[@]}" "mkdir -p '$DEST'"
    "${SCP[@]}" "$HERE/build/ipadctld" "root@$HOST:$DEST/ipadctld.new"
    "${SCP[@]}" "$HERE/ents.plist" "root@$HOST:$DEST/ents.plist"
    "${SCP[@]}" "$HERE/com.max.ipadctld.plist" "root@$HOST:$DEST/com.max.ipadctld.plist"
    "${SSH[@]}" "set -e; cd '$DEST'
        ldid -Sents.plist ipadctld.new
        chmod 755 ipadctld.new
        launchctl unload '$PLIST' 2>/dev/null || launchctl bootout system/$LABEL 2>/dev/null || true
        mv -f ipadctld.new ipadctld
        ldid -e ipadctld | grep -c '<key>' | sed 's/^/entitlement keys: /'
        launchctl load '$PLIST' 2>/dev/null || launchctl bootstrap system '$PLIST' 2>/dev/null || true
        sleep 1
        launchctl list | awk '/$LABEL/{print \"loaded: \" \$0}'"
    echo "deployed. token: run 'ipadctl/daemon/deploy.sh token'"
}

do_status() {
    "${SSH[@]}" "launchctl list | awk '/$LABEL/{print \"loaded: \" \$0}'; echo '--- last log ---'; tail -n 20 '$DEST/actions.log' 2>/dev/null; echo '--- stderr ---'; tail -n 10 '$DEST/ipadctld.err.log' 2>/dev/null"
}

do_token() {
    "${SSH[@]}" "cat '$DEST/token' 2>/dev/null || echo 'no token yet (start the daemon once)'"
}

case "${1:-deploy}" in
    deploy) do_deploy ;;
    build) do_build ;;
    start) do_start ;;
    stop) do_stop ;;
    status) do_status ;;
    token) do_token ;;
    *) echo "usage: $0 {deploy|build|start|stop|status|token}" >&2; exit 2 ;;
esac
