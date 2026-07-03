#!/usr/bin/env bash
# Install the on-device launcher sync tools.
#
# This is the dev/iteration path for "installed .desktop apps become iPad Home
# Screen apps" without a Mac-side generator. It installs:
#   /var/jb/usr/local/bin/xios-icon-render
#   /var/jb/usr/local/bin/xios-launcher-sync
#   /var/jb/usr/libexec/xios-launchers/{IOSCHost,IOSCLaunch,default.metallib,*entitlements.plist}
#
# It does NOT create/remove Home Screen apps by itself; run xios-launcher-sync
# on-device for that.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/deploy-env.sh"   # IP/PORT/SSH_OPTS + ssh_/scp_

HOST_DIR="$(cd "$HERE/../iosc-host" && pwd)"
[ -x "$HERE/out/IOSCLaunch" ] || bash "$HERE/build-stub.sh"
[ -x "$HOST_DIR/out/IOSCHost" ] || bash "$HOST_DIR/build-host.sh"
[ -f "$HOST_DIR/out/default.metallib" ] || bash "$HOST_DIR/build-host.sh"

echo "==> stage sources"
scp_ "$HERE/src/xios-icon-render.c" "root@$IP:/var/jb/tmp/xios-icon-render.c"
scp_ "$HERE/src/xios-launcher-sync.c" "root@$IP:/var/jb/tmp/xios-launcher-sync.c"

echo "==> install shared payloads"
ssh_ "mkdir -p /var/jb/usr/libexec/xios-launchers"
scp_ "$HERE/out/IOSCLaunch" "$HOST_DIR/out/IOSCHost" "$HOST_DIR/out/default.metallib" \
    "root@$IP:/var/jb/usr/libexec/xios-launchers/"
scp_ "$HERE/launcher-ent.xml" \
    "root@$IP:/var/jb/usr/libexec/xios-launchers/launcher-entitlements.plist"
scp_ "$HOST_DIR/entitlements.plist" \
    "root@$IP:/var/jb/usr/libexec/xios-launchers/host-entitlements.plist"

echo "==> compile on device"
ssh_ "set -e
  cc /var/jb/tmp/xios-icon-render.c -o /var/jb/usr/local/bin/xios-icon-render \
    \$(pkg-config --cflags --libs gdk-pixbuf-2.0) -Wl,-rpath,/var/jb/usr/lib -lm
  cc /var/jb/tmp/xios-launcher-sync.c -o /var/jb/usr/local/bin/xios-launcher-sync \
    -Wl,-rpath,/var/jb/usr/lib
  ldid -S /var/jb/usr/local/bin/xios-icon-render || true
  ldid -S /var/jb/usr/local/bin/xios-launcher-sync || true
  chmod 0755 /var/jb/usr/local/bin/xios-icon-render /var/jb/usr/local/bin/xios-launcher-sync
  chmod 0755 /var/jb/usr/libexec/xios-launchers/IOSCHost /var/jb/usr/libexec/xios-launchers/IOSCLaunch
  chmod 0644 /var/jb/usr/libexec/xios-launchers/default.metallib \
             /var/jb/usr/libexec/xios-launchers/*entitlements.plist"

echo "==> installed"
ssh_ "/var/jb/usr/local/bin/xios-launcher-sync --list | sed -n '1,20p'"
echo "    To stage-test without touching SpringBoard:"
echo "      /var/jb/usr/local/bin/xios-launcher-sync --sync --native --apps-dir /var/jb/tmp/xios-sync-test --no-uicache"
echo "    To create/update Home Screen apps:"
echo "      /var/jb/usr/local/bin/xios-launcher-sync --sync --native"
