#!/usr/bin/env bash
# Generate xdg-shell protocol glue for mesa-demos' EGLUT Wayland backend.
set -euo pipefail

tree="${1:?usage: mesa-demos-generate-xdg-shell.sh <mesa-demos tree>}"
root="$tree/src/egl/eglut"

scanner=""
for candidate in \
  /work/Procursus/build_work/iphoneos-arm64-rootless/1900/wayland/native-root/bin/wayland-scanner \
  /work/Procursus/build_work/iphoneos-arm64-rootless/1900/wayland/build-native/src/wayland-scanner \
  /work/Procursus/build_base/iphoneos-arm64-rootless/1900/var/jb/usr/bin/wayland-scanner; do
  if [ -x "$candidate" ]; then
    scanner="$candidate"
    break
  fi
done

xml=""
for candidate in \
  /work/Procursus/build_base/iphoneos-arm64-rootless/1900/var/jb/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml \
  /work/Procursus/build_stage/iphoneos-arm64-rootless/1900/wayland-protocols/var/jb/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml \
  /work/Procursus/build_work/iphoneos-arm64-rootless/1900/wayland-protocols/stable/xdg-shell/xdg-shell.xml; do
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
