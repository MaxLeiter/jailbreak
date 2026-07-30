#!/usr/bin/env bash
# Generate xdg-shell protocol glue for mesa-demos' EGLUT Wayland backend.
set -euo pipefail
[ -r "${XIOS_TARGET_ENV:=/work/target-env.sh}" ] || { echo "ERROR: $XIOS_TARGET_ENV missing; rebuild the toolchain image (docker build x11/linux-build) or mount target-env.sh there" >&2; exit 1; }
. "$XIOS_TARGET_ENV"

tree="${1:?usage: mesa-demos-generate-xdg-shell.sh <mesa-demos tree>}"
root="$tree/src/egl/eglut"

scanner=""
for candidate in \
  $XIOS_BUILD_WORK/wayland/native-root/bin/wayland-scanner \
  $XIOS_BUILD_WORK/wayland/build-native/src/wayland-scanner \
  $XIOS_SYSROOT/usr/bin/wayland-scanner; do
  if [ -x "$candidate" ]; then
    scanner="$candidate"
    break
  fi
done

xml=""
for candidate in \
  $XIOS_SYSROOT/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml \
  $XIOS_BUILD_STAGE/wayland-protocols$XIOS_PREFIX/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml \
  $XIOS_BUILD_WORK/wayland-protocols/stable/xdg-shell/xdg-shell.xml; do
  if [ -f "$candidate" ]; then
    xml="$candidate"
    break
  fi
done

[ -n "$scanner" ] || { echo "mesa-demos: missing wayland-scanner" >&2; exit 1; }
[ -n "$xml" ] || { echo "mesa-demos: missing xdg-shell.xml" >&2; exit 1; }

"$scanner" client-header "$xml" "$root/xdg-shell-client-protocol.h"
if ! "$scanner" private-code "$xml" "$root/xdg-shell-protocol.c"; then
  "$scanner" code "$xml" "$root/xdg-shell-protocol.c"
fi
