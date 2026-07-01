#!/usr/bin/env bash
#
# build-panel.sh — cross-compile ioscpanel (the iosc desktop panel) for rootless
# iOS arm64. Mirrors wayland/build-iosc.sh: a standalone clang invocation inside
# procursus-xbuild:bookworm-arm64 (cctools aarch64-apple-darwin-clang + iPhoneOS
# SDK), NOT the Procursus Makefile.
#
# Unlike iosc (a libwayland-SERVER program needing epoll-shim), ioscpanel is a
# pure libwayland-CLIENT program: it needs only libwayland-client.dylib at link
# time and rolls its own poll() loop, so the sysroot is small.
#
# Usage:
#   ./build-panel.sh                 # auto-locate the W0 sysroot debs in the repo
#   SYSROOT=/path/to/extracted ./build-panel.sh
#
# Output: out/ioscpanel  (ldid-signed, ready to scp to /var/jb/usr/local/bin)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE=procursus-xbuild:bookworm-arm64
OUT="$HERE/out"
mkdir -p "$OUT"

# --- locate the W0 wayland-client dev + runtime debs -----------------------
# The W0 build (memory: wayland-w0-ios-build) produces libwayland-dev_*.deb and
# the runtime libwayland-client.0.dylib. Search the usual spots; override with
# SYSROOT if you already have an extracted tree (must contain
#   var/jb/usr/include/wayland-client.h and var/jb/usr/lib/libwayland-client*.dylib).
REPO_ROOT="$(cd "$HERE/../.." && pwd)"          # .../x11
find_deb() { find "$REPO_ROOT" -name "$1" 2>/dev/null | head -1; }

SYSROOT="${SYSROOT:-}"
if [[ -z "$SYSROOT" ]]; then
  WL_DEV_DEB="$(find_deb 'libwayland-dev_*.deb')"
  WL_RUN_DEB="$(find_deb 'libwayland-client*_*.deb')"
  [[ -z "$WL_RUN_DEB" ]] && WL_RUN_DEB="$(find_deb 'libwayland*0_*.deb')"
  if [[ -z "$WL_DEV_DEB" ]]; then
    echo "ERROR: could not find libwayland-dev_*.deb under $REPO_ROOT" >&2
    echo "       Build the W0 stack first (wayland-w0-ios-build) or set SYSROOT=." >&2
    exit 1
  fi
  SYSROOT="$OUT/sysroot"
  rm -rf "$SYSROOT"; mkdir -p "$SYSROOT"
  dpkg-deb -x "$WL_DEV_DEB" "$SYSROOT"
  [[ -n "$WL_RUN_DEB" ]] && dpkg-deb -x "$WL_RUN_DEB" "$SYSROOT" || true
  echo "extracted sysroot from:"
  echo "  $WL_DEV_DEB"
  [[ -n "$WL_RUN_DEB" ]] && echo "  $WL_RUN_DEB"
fi

# --- run the cross-build inside the toolchain image ------------------------
docker run --rm --entrypoint /bin/bash \
  -v "$HERE":/work -v "$SYSROOT":/sysroot:ro \
  "$IMAGE" -euo pipefail -c '
    CC=/root/cctools/bin/aarch64-apple-darwin-clang
    SDK=/root/cctools/SDK/iPhoneOS16.5.sdk
    cd /work

    # wayland-scanner (Debian 1.21 — ABI-stable vs the 1.23.1 W0 libs, same as iosc)
    if ! command -v wayland-scanner >/dev/null; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq && apt-get install -y -qq libwayland-bin >/dev/null
    fi

    mkdir -p gen
    for p in wlr-layer-shell-unstable-v1 wlr-foreign-toplevel-management-unstable-v1 xdg-shell; do
      wayland-scanner client-header protocols/$p.xml gen/$p-client-protocol.h
      wayland-scanner private-code  protocols/$p.xml gen/$p-protocol.c
    done

    SYSINC=/sysroot/var/jb/usr/include
    SYSLIB=/sysroot/var/jb/usr/lib
    CFLAGS="-arch arm64 -isysroot $SDK -Igen -I$SYSINC -Wall -Wextra -O2 -std=gnu11"
    # link: only libwayland-client (+ libSystem implicit). @rpath = on-device libdir.
    LDFLAGS="-arch arm64 -isysroot $SDK -L$SYSLIB -lwayland-client \
             -Wl,-rpath,/var/jb/usr/lib -framework CoreFoundation"

    $CC $CFLAGS -c gen/wlr-layer-shell-unstable-v1-protocol.c -o gen/layer.o
    $CC $CFLAGS -c gen/wlr-foreign-toplevel-management-unstable-v1-protocol.c -o gen/ftm.o
    $CC $CFLAGS -c gen/xdg-shell-protocol.c -o gen/xdg.o
    PROTO="gen/layer.o gen/ftm.o gen/xdg.o"
    # both shell clients share shell-draw.h (the wl_shm renderer)
    for client in ioscpanel ioscoverview; do
      $CC $CFLAGS -c $client.c -o gen/$client.o
      $CC gen/$client.o $PROTO $LDFLAGS -o out/$client
      echo "linked: out/$client"
    done
    /root/cctools/bin/aarch64-apple-darwin-otool -L out/ioscpanel | head
  '

# --- ad-hoc sign with the client entitlements ------------------------------
# A wl_shm client needs no GPU/IOSurface entitlements (memory: kgx cairo→wl_shm
# needs no re-sign). panel-ent.xml = the minimal iosc-client set so it can spawn
# launched apps and reach the wayland socket.
if command -v ldid >/dev/null; then
  for b in ioscpanel ioscoverview; do
    ldid -S"$HERE/panel-ent.xml" "$OUT/$b" && echo "signed: $OUT/$b"
  done
else
  echo "NOTE: ldid not on host PATH; sign on-device: ldid -Spanel-ent.xml ioscpanel ioscoverview" >&2
fi

echo "DONE -> $OUT/ioscpanel  $OUT/ioscoverview"
echo "Deploy: scp out/iosc{panel,overview} root@ipad:/var/jb/usr/local/bin/ && (sign if not already)"
echo "Run (needs iosc with zwlr_layer_shell_v1):"
echo "  WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/var/jb/tmp ioscpanel     # the top bar"
echo "  WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/var/jb/tmp ioscoverview  # the app grid (Escape/tap to dismiss)"
