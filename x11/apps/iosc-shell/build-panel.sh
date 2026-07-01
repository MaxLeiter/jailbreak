#!/usr/bin/env bash
#
# build-panel.sh — cross-compile the iosc shell clients for rootless iOS arm64.
#
#   ioscpanel     — the desktop panel. Draws with cairo + pangocairo (real SF
#                   text, rounded surfaces, PNG app icons), so it links the staged
#                   GTK stack (procursus-vol-gtk) via cross-pkg-config.
#   ioscoverview  — the app overview. Still the wl_shm bitmap renderer, so it
#                   links only libwayland-client.
#
# Both are pure libwayland-CLIENT programs (own poll() loop). The GTK-stack
# dylibs (cairo/pango/glib/…) resolve on device from /var/jb/usr/lib via @rpath.
#
# Usage: ./build-panel.sh
# Output: out/ioscpanel, out/ioscoverview (ldid-signed with panel-ent.xml).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE=procursus-xbuild:bookworm-arm64
GTK_VOL=procursus-vol-gtk
OUT="$HERE/out"
mkdir -p "$OUT"

if ! docker volume ls --format '{{.Name}}' | grep -qx "$GTK_VOL"; then
  echo "ERROR: docker volume $GTK_VOL not found (the staged GTK stack)." >&2
  echo "       It provides cairo/pango/glib/wayland-client for the iOS cross-link." >&2
  exit 1
fi

docker run --rm --entrypoint /bin/bash \
  -v "$HERE":/work -v "$GTK_VOL":/work/Procursus:ro \
  "$IMAGE" -euo pipefail -c '
    export BUILD_BASE=/work/Procursus/build_base/iphoneos-arm64-rootless/1900
    export MEMO_PREFIX=/var/jb MEMO_SUB_PREFIX=/usr MEMO_ALT_PREFIX=
    PKGC=/work/Procursus/build_tools/cross-pkg-config
    CC=/root/cctools/bin/aarch64-apple-darwin-clang
    OTOOL=/root/cctools/bin/aarch64-apple-darwin-otool
    INT=/root/cctools/bin/aarch64-apple-darwin-install_name_tool
    SDK=/root/cctools/SDK/iPhoneOS.sdk
    cd /work

    # Linux wayland-scanner (Debian) — ABI-stable vs the staged 1.23 libs.
    if ! command -v wayland-scanner >/dev/null; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq && apt-get install -y -qq libwayland-bin >/dev/null
    fi

    mkdir -p gen
    for p in wlr-layer-shell-unstable-v1 wlr-foreign-toplevel-management-unstable-v1 xdg-shell; do
      wayland-scanner client-header protocols/$p.xml gen/$p-client-protocol.h
      wayland-scanner private-code  protocols/$p.xml gen/$p-protocol.c
    done

    BASE="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0 -Igen -I/work \
          -isystem $BUILD_BASE/var/jb/usr/include -Wall -Wextra -O2 -std=gnu11"
    # The staged iOS SDK headers macro-rename exec*()->ie_exec*() (the Procursus
    # iosexec posix_spawn shim); sd_launch() uses execl, so both clients link it.
    RPATH="-Wl,-rpath,/var/jb/usr/lib -framework CoreFoundation -liosexec"

    WL_CFLAGS=$("$PKGC" --cflags wayland-client)
    WL_LIBS=$("$PKGC" --libs wayland-client)
    UI_CFLAGS=$("$PKGC" --cflags wayland-client cairo pangocairo)
    UI_LIBS=$("$PKGC" --libs wayland-client cairo pangocairo)

    # protocol marshalling objects (shared by both clients)
    $CC $BASE $WL_CFLAGS -c gen/wlr-layer-shell-unstable-v1-protocol.c -o gen/layer.o
    $CC $BASE $WL_CFLAGS -c gen/wlr-foreign-toplevel-management-unstable-v1-protocol.c -o gen/ftm.o
    $CC $BASE $WL_CFLAGS -c gen/xdg-shell-protocol.c -o gen/xdg.o
    PROTO="gen/layer.o gen/ftm.o gen/xdg.o"

    echo "== linking ioscpanel (cairo/pangocairo) =="
    $CC $BASE $UI_CFLAGS -c ioscpanel.c -o gen/ioscpanel.o
    $CC gen/ioscpanel.o $PROTO $UI_LIBS $RPATH -o out/ioscpanel

    echo "== linking ioscoverview (wl_shm bitmap) =="
    $CC $BASE $WL_CFLAGS -c ioscoverview.c -o gen/ioscoverview.o
    $CC gen/ioscoverview.o $PROTO $WL_LIBS $RPATH -o out/ioscoverview

    # Match the shipped gettext: device has libintl.8.dylib, not libintl.dylib
    # (same fixup as build-hello-gtk.sh).
    "$INT" -change @rpath/libintl.dylib @rpath/libintl.8.dylib out/ioscpanel 2>/dev/null || true

    echo "== ioscpanel linked dylibs =="
    "$OTOOL" -L out/ioscpanel | grep -iE "cairo|pango|glib|gobject|wayland|intl|harfbuzz|fontconfig" | head -20
  '

# --- ad-hoc sign with the client entitlements ------------------------------
if command -v ldid >/dev/null; then
  for b in ioscpanel ioscoverview; do
    ldid -S"$HERE/panel-ent.xml" "$OUT/$b" && echo "signed: $OUT/$b"
  done
else
  echo "NOTE: ldid not on host PATH; sign on-device: ldid -Spanel-ent.xml ioscpanel ioscoverview" >&2
fi

echo "DONE -> $OUT/ioscpanel  $OUT/ioscoverview"
echo "Deploy: scp out/iosc{panel,overview} root@ipad:/var/jb/usr/local/bin/"
echo "Run (needs iosc with zwlr_layer_shell_v1):"
echo "  WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/var/jb/tmp ioscpanel"
