#!/usr/bin/env bash
# Legacy Bun/OpenCode bring-up probes for rootless iOS.
#
# Runs INSIDE the procursus-xbuild Docker image. This is intentionally isolated
# from the Procursus recipe graph: first prove the iPhoneOS toolchain/device loop
# and the upstream Bun binary failure mode. Current package builds live in
# build-bun-ios.sh / run-bun-ios.sh; keep this script for preflight probes.
set -euo pipefail
umask 022

OUT="${OUT:-/out}"
WORK="${WORK:-/work/bun-spike}"
IOS_MIN="${IOS_MIN:-16.0}"
mkdir -p "$OUT" "$WORK"

build_preflight() {
  echo "==> build iphoneos-arm64 preflight binary"
  cat > "$WORK/bun-preflight.c" <<'EOF'
#include <stdio.h>
#include <unistd.h>
#include <sys/utsname.h>

int main(void) {
  struct utsname u;
  if (uname(&u) != 0) {
    perror("uname");
    return 1;
  }

  printf("bun-preflight: hello from %s %s %s\n", u.sysname, u.machine, u.release);
  printf("bun-preflight: uid=%d\n", getuid());
  return 0;
}
EOF

  aarch64-apple-darwin-clang \
    -isysroot /root/cctools/SDK/iPhoneOS.sdk \
    -miphoneos-version-min="$IOS_MIN" \
    -Os "$WORK/bun-preflight.c" \
    -o "$OUT/bun-preflight"
  ldid -S "$OUT/bun-preflight"
  file "$OUT/bun-preflight"

  echo "==> package bun-preflight deb"
  rm -rf "$WORK/pkg"
  mkdir -p "$WORK/pkg/DEBIAN" "$WORK/pkg/var/jb/usr/bin"
  cp "$OUT/bun-preflight" "$WORK/pkg/var/jb/usr/bin/bun-preflight"
  cat > "$WORK/pkg/DEBIAN/control" <<'EOF'
Package: bun-preflight
Name: Bun Preflight
Version: 0.0.1
Architecture: iphoneos-arm64
Description: Toolchain/device smoke test for the Bun on iOS port.
Maintainer: max
Author: max
Section: Development
Priority: optional
EOF
  dpkg-deb -Zxz -b "$WORK/pkg" "$OUT/bun-preflight_0.0.1_iphoneos-arm64.deb"
}

probe_official_bun() {
  echo "==> download upstream darwin-arm64 Bun binary for the expected-failure probe"
  rm -rf "$WORK/upstream"
  mkdir -p "$WORK/upstream"
  curl -fsSL \
    -o "$WORK/upstream/bun-darwin-aarch64.zip" \
    https://github.com/oven-sh/bun/releases/latest/download/bun-darwin-aarch64.zip
  python3 - "$WORK/upstream/bun-darwin-aarch64.zip" "$WORK/upstream" <<'PY'
import sys, zipfile
archive, out = sys.argv[1:]
with zipfile.ZipFile(archive) as zf:
    zf.extractall(out)
PY
  cp "$WORK/upstream/bun-darwin-aarch64/bun" "$OUT/bun-darwin-arm64-upstream"
  chmod +x "$OUT/bun-darwin-arm64-upstream"
  ldid -S "$OUT/bun-darwin-arm64-upstream" || true
  file "$OUT/bun-darwin-arm64-upstream"
  echo "   NOTE: this is a macOS-platform Mach-O; on iOS it is expected to fail at dyld."
}

case "${1:-all}" in
  all)
    build_preflight
    probe_official_bun
    ;;
  preflight)
    build_preflight
    ;;
  upstream-probe)
    probe_official_bun
    ;;
  *)
    echo "usage: $0 [all|preflight|upstream-probe]" >&2
    exit 2
    ;;
esac

echo "==> bun spike artifacts:"
ls -lh "$OUT"/bun-* 2>/dev/null || true
