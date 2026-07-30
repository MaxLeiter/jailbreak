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
_xt="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [ "$_xt" != / ] && [ ! -f "$_xt/linux-build/target-lib.sh" ]; do _xt="$(dirname "$_xt")"; done
. "$_xt/linux-build/target-lib.sh"
xios_load_target "${XIOS_TARGET:-rootless-1900}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/deploy-env.sh"   # IP/PORT/SSH_OPTS + ssh_/scp_

HOST_DIR="$(cd "$HERE/../iosc-host" && pwd)"
[ -x "$HERE/out/IOSCLaunch" ] || bash "$HERE/build-stub.sh"
[ -x "$HOST_DIR/out/IOSCHost" ] || bash "$HOST_DIR/build-host.sh"
[ -f "$HOST_DIR/out/default.metallib" ] || bash "$HOST_DIR/build-host.sh"

echo "==> stage sources"
scp_ "$HERE/src/xios-icon-render.c" "root@$IP:$XIOS_PREFIX/tmp/xios-icon-render.c"
scp_ "$HERE/src/xios-launcher-sync.c" "$HERE/src/xios-desktop-entry.c" \
     "$HERE/src/xios-desktop-entry.h" "root@$IP:$XIOS_PREFIX/tmp/"

echo "==> install shared payloads"
ssh_ "mkdir -p $XIOS_PREFIX/usr/libexec/xios-launchers"
scp_ "$HERE/out/IOSCLaunch" "$HOST_DIR/out/IOSCHost" "$HOST_DIR/out/default.metallib" \
    "root@$IP:$XIOS_PREFIX/usr/libexec/xios-launchers/"
scp_ "$HERE/launcher-ent.xml" \
    "root@$IP:$XIOS_PREFIX/usr/libexec/xios-launchers/launcher-entitlements.plist"
scp_ "$HOST_DIR/entitlements.plist" \
    "root@$IP:$XIOS_PREFIX/usr/libexec/xios-launchers/host-entitlements.plist"

echo "==> compile on device"
ssh_ "set -e
  cc $XIOS_PREFIX/tmp/xios-icon-render.c -o $XIOS_PREFIX/usr/local/bin/xios-icon-render \
    \$(pkg-config --cflags --libs gdk-pixbuf-2.0) -Wl,-rpath,$XIOS_PREFIX/usr/lib -lm
  cc $XIOS_PREFIX/tmp/xios-launcher-sync.c $XIOS_PREFIX/tmp/xios-desktop-entry.c \
    -o $XIOS_PREFIX/usr/local/bin/xios-launcher-sync \
    -Wl,-rpath,$XIOS_PREFIX/usr/lib
  ldid -S $XIOS_PREFIX/usr/local/bin/xios-icon-render || true
  ldid -S $XIOS_PREFIX/usr/local/bin/xios-launcher-sync || true
  chmod 0755 $XIOS_PREFIX/usr/local/bin/xios-icon-render $XIOS_PREFIX/usr/local/bin/xios-launcher-sync
  chmod 0755 $XIOS_PREFIX/usr/libexec/xios-launchers/IOSCHost $XIOS_PREFIX/usr/libexec/xios-launchers/IOSCLaunch
  chmod 0644 $XIOS_PREFIX/usr/libexec/xios-launchers/default.metallib \
             $XIOS_PREFIX/usr/libexec/xios-launchers/*entitlements.plist"

echo "==> installed"
ssh_ "$XIOS_PREFIX/usr/local/bin/xios-launcher-sync --list | sed -n '1,20p'"
echo "    To stage-test without touching SpringBoard:"
echo "      $XIOS_PREFIX/usr/local/bin/xios-launcher-sync --sync --native --apps-dir $XIOS_PREFIX/tmp/xios-sync-test --no-uicache"
echo "    To create/update Home Screen apps:"
echo "      $XIOS_PREFIX/usr/local/bin/xios-launcher-sync --sync --native"
