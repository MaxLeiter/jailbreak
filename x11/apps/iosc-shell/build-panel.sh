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

# --- locate the W0 wayland debs --------------------------------------------
# The W0 build (memory: wayland-w0-ios-build) produces libwayland-dev_*.deb (the
# headers + the .dylib link stub) and libwayland0_*.deb (the runtime dylib), in
# linux-build/out/. Extraction happens INSIDE the container (dpkg-deb is not on a
# macOS host). Override with SYSROOT=/path to a pre-extracted tree (must contain
#   var/jb/usr/include/wayland-client.h and var/jb/usr/lib/libwayland-client*.dylib).
REPO_ROOT="$(cd "$HERE/../.." && pwd)"          # .../x11
DEBS_DIR="$REPO_ROOT/linux-build/out"
SYSROOT="${SYSROOT:-}"
if [[ -z "$SYSROOT" && ! -d "$DEBS_DIR" ]]; then
  echo "ERROR: $DEBS_DIR not found and no SYSROOT set (build the W0 stack first)." >&2
  exit 1
fi

# --- run the cross-build inside the toolchain image ------------------------
docker run --rm --entrypoint /bin/bash \
  -v "$HERE":/work -v "$DEBS_DIR":/debs:ro \
  ${SYSROOT:+-v "$SYSROOT":/presysroot:ro} \
  "$IMAGE" -euo pipefail -c '
    CC=/root/cctools/bin/aarch64-apple-darwin-clang
    SDK=/root/cctools/SDK/iPhoneOS16.5.sdk
    cd /work

    # Sysroot: use a pre-extracted tree if mounted, else extract the W0 debs here
    # (dpkg-deb lives in the container, not on the macOS host).
    if [ -d /presysroot ]; then
      SYS=/presysroot
    else
      SYS=/tmp/wl-sysroot; rm -rf $SYS; mkdir -p $SYS
      dev=$(ls /debs/libwayland-dev_*_iphoneos-arm64.deb 2>/dev/null | head -1)
      run=$(ls /debs/libwayland0_*_iphoneos-arm64.deb /debs/libwayland-client*_*_iphoneos-arm64.deb 2>/dev/null | head -1 || true)
      [ -n "$dev" ] || { echo "ERROR: libwayland-dev_*.deb not in /debs"; exit 1; }
      dpkg-deb -x "$dev" $SYS
      [ -n "$run" ] && dpkg-deb -x "$run" $SYS || true
      echo "extracted W0 sysroot: $(basename "$dev") ${run:+$(basename "$run")}"
    fi

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

    SYSINC=$SYS/var/jb/usr/include
    SYSLIB=$SYS/var/jb/usr/lib
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
