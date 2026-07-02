#!/usr/bin/env bash
#
# build-panel.sh — cross-compile the iosc shell clients for iOS arm64.
#
#   ioscbar       — the slim tablet status bar + Control Center.
#   ioscdock      — the floating tablet dock (favorites + running apps).
#   ioscoverview  — the launcher/window switcher. Same cairo stack + screencopy
#                   (frosted desktop backdrop).
#   ioscbg        — the wallpaper + draggable desktop widgets. Uses cairo for
#                   widget typography and CoreGraphics/ImageIO for wallpaper decode.
#
# All are pure libwayland-CLIENT programs (own poll() loop). The GTK-stack
# dylibs (cairo/pango/glib/…) resolve on device from the selected Procursus
# prefix via @rpath (/var/jb/usr/lib for rootless, /usr/lib for rootful).
#
# Usage: ./build-panel.sh
# Output: out/ioscbar, out/ioscdock, out/ioscoverview, out/ioscbg.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
IMAGE=procursus-xbuild:bookworm-arm64
GTK_VOL="${IOSC_PROC_VOL:-${GTK_VOL:-procursus-vol-gtk}}"
OUT="$HERE/out"
SCHEME="${IOSC_PACKAGE_SCHEME:-${THEOS_PACKAGE_SCHEME:-rootless}}"
CFVER="${MEMO_CFVER:-1900}"

case "$SCHEME" in
  rootless)
    MEMO_TARGET_DEFAULT=iphoneos-arm64-rootless
    MEMO_PREFIX_DEFAULT=/var/jb
    ;;
  rootful)
    MEMO_TARGET_DEFAULT=iphoneos-arm64
    MEMO_PREFIX_DEFAULT=
    ;;
  *)
    echo "ERROR: IOSC_PACKAGE_SCHEME/THEOS_PACKAGE_SCHEME must be rootless or rootful (got $SCHEME)" >&2
    exit 1
    ;;
esac

MEMO_TARGET="${MEMO_TARGET:-$MEMO_TARGET_DEFAULT}"
MEMO_PREFIX="${MEMO_PREFIX-$MEMO_PREFIX_DEFAULT}"
MEMO_SUB_PREFIX="${MEMO_SUB_PREFIX:-/usr}"
MEMO_ALT_PREFIX="${MEMO_ALT_PREFIX:-}"
BUILD_BASE="/work/Procursus/build_base/$MEMO_TARGET/$CFVER"
SYSROOT_PREFIX="$BUILD_BASE$MEMO_PREFIX$MEMO_SUB_PREFIX"
RPATH_PREFIX="$MEMO_PREFIX$MEMO_SUB_PREFIX"

mkdir -p "$OUT"

if ! docker volume ls --format '{{.Name}}' | grep -qx "$GTK_VOL"; then
  echo "ERROR: docker volume $GTK_VOL not found (the staged GTK stack)." >&2
  echo "       It provides cairo/pango/glib/wayland-client for the iOS cross-link." >&2
  exit 1
fi

docker run --rm --entrypoint /bin/bash \
  -e BUILD_BASE="$BUILD_BASE" \
  -e MEMO_TARGET="$MEMO_TARGET" \
  -e MEMO_CFVER="$CFVER" \
  -e MEMO_PREFIX="$MEMO_PREFIX" \
  -e MEMO_SUB_PREFIX="$MEMO_SUB_PREFIX" \
  -e MEMO_ALT_PREFIX="$MEMO_ALT_PREFIX" \
  -e IOSC_PACKAGE_SCHEME="$SCHEME" \
  -e SYSROOT_PREFIX="$SYSROOT_PREFIX" \
  -e RPATH_PREFIX="$RPATH_PREFIX" \
  -v "$HERE":/work -v "$GTK_VOL":/work/Procursus:ro \
  "$IMAGE" -euo pipefail -c '
    PKGC=/work/Procursus/build_tools/cross-pkg-config
    CC=/root/cctools/bin/aarch64-apple-darwin-clang
    OTOOL=/root/cctools/bin/aarch64-apple-darwin-otool
    INT=/root/cctools/bin/aarch64-apple-darwin-install_name_tool
    SDK=/root/cctools/SDK/iPhoneOS.sdk
    cd /work

    if [ ! -d "$SYSROOT_PREFIX/include" ] || [ ! -d "$SYSROOT_PREFIX/lib" ] ||
       [ ! -f "$SYSROOT_PREFIX/lib/pkgconfig/wayland-client.pc" ]; then
      echo "ERROR: missing selected Procursus sysroot at $SYSROOT_PREFIX" >&2
      echo "       expected $SYSROOT_PREFIX/lib/pkgconfig/wayland-client.pc" >&2
      echo "       scheme=$IOSC_PACKAGE_SCHEME target=$MEMO_TARGET prefix=${MEMO_PREFIX:-/}; set IOSC_PROC_VOL/GTK_VOL or build that target first." >&2
      exit 1
    fi

    # Linux wayland-scanner (Debian) — ABI-stable vs the staged 1.23 libs.
    if ! command -v wayland-scanner >/dev/null; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq && apt-get install -y -qq libwayland-bin >/dev/null
    fi

    mkdir -p gen
    for p in wlr-layer-shell-unstable-v1 wlr-foreign-toplevel-management-unstable-v1 \
             wlr-screencopy-unstable-v1 xdg-shell; do
      wayland-scanner client-header protocols/$p.xml gen/$p-client-protocol.h
      wayland-scanner private-code  protocols/$p.xml gen/$p-protocol.c
    done

    BASE="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0 -Igen -I/work \
          -isystem $SYSROOT_PREFIX/include -Wall -Wextra -O2 -std=gnu11"
    # Link lines need the deployment target too, else ld64 stamps the SDK
    # version (16.5) as LC_BUILD_VERSION minos and the deb floor overshoots.
    LINK="-arch arm64 -isysroot $SDK -miphoneos-version-min=16.0"
    # The staged iOS SDK headers macro-rename exec*()->ie_exec*() (the Procursus
    # iosexec posix_spawn shim); sd_launch() uses execl, so all clients link it.
    RPATH="-Wl,-rpath,$RPATH_PREFIX/lib -framework CoreFoundation -liosexec"

    WL_CFLAGS=$("$PKGC" --cflags wayland-client)
    WL_LIBS=$("$PKGC" --libs wayland-client)
    UI_CFLAGS=$("$PKGC" --cflags wayland-client cairo pangocairo)
    UI_LIBS=$("$PKGC" --libs wayland-client cairo pangocairo)

    # protocol marshalling objects (shared)
    $CC $BASE $WL_CFLAGS -c gen/wlr-layer-shell-unstable-v1-protocol.c -o gen/layer.o
    $CC $BASE $WL_CFLAGS -c gen/wlr-foreign-toplevel-management-unstable-v1-protocol.c -o gen/ftm.o
    $CC $BASE $WL_CFLAGS -c gen/wlr-screencopy-unstable-v1-protocol.c -o gen/scopy.o
    $CC $BASE $WL_CFLAGS -c gen/xdg-shell-protocol.c -o gen/xdg.o
    PROTO="gen/layer.o gen/ftm.o gen/scopy.o gen/xdg.o"

    echo "== linking shell chrome (cairo/pangocairo + screencopy) =="
    $CC $BASE $UI_CFLAGS -c iosc-shell.c -o gen/iosc-shell.o
    $CC $LINK gen/iosc-shell.o $PROTO $UI_LIBS $RPATH -o out/ioscbar
    cp out/ioscbar out/ioscdock

    echo "== linking ioscoverview (cairo/pangocairo + screencopy) =="
    $CC $BASE $UI_CFLAGS -c ioscoverview.c -o gen/ioscoverview.o
    $CC $LINK gen/ioscoverview.o $PROTO $UI_LIBS $RPATH -o out/ioscoverview

    echo "== linking ioscbg (cairo/pangocairo + CoreGraphics/ImageIO) =="
    $CC $BASE $UI_CFLAGS -c ioscbg.c -o gen/ioscbg.o
    $CC $LINK gen/ioscbg.o gen/layer.o gen/xdg.o $UI_LIBS $RPATH \
        -framework CoreGraphics -framework ImageIO -o out/ioscbg

    # Match the shipped gettext: device has libintl.8.dylib, not libintl.dylib
    # (same fixup as build-hello-gtk.sh).
    for b in out/ioscbar out/ioscdock out/ioscoverview out/ioscbg; do
      "$INT" -change @rpath/libintl.dylib @rpath/libintl.8.dylib "$b" 2>/dev/null || true
    done

    echo "== ioscbar linked dylibs =="
    "$OTOOL" -L out/ioscbar | grep -iE "cairo|pango|glib|gobject|wayland|intl|harfbuzz|fontconfig" | head -20
    echo "== ioscbg linked dylibs/frameworks =="
    "$OTOOL" -L out/ioscbg | grep -iE "cairo|pango|glib|gobject|wayland|intl|CoreGraphics|ImageIO|CoreFoundation" | head -20
  '

# --- ad-hoc sign with the client entitlements ------------------------------
if command -v ldid >/dev/null; then
  for b in ioscbar ioscdock ioscoverview ioscbg; do
    ldid -S"$HERE/panel-ent.xml" "$OUT/$b" && echo "signed: $OUT/$b"
  done
else
  echo "NOTE: ldid not on host PATH; sign on-device: ldid -Spanel-ent.xml iosc{bar,dock,overview,bg}" >&2
fi

echo "DONE -> $OUT/ioscbar  $OUT/ioscdock  $OUT/ioscoverview  $OUT/ioscbg"
echo "scheme=$SCHEME target=$MEMO_TARGET prefix=${MEMO_PREFIX:-/}"
echo "Deploy: scp out/iosc{bar,dock,overview,bg} root@ipad:${MEMO_PREFIX}/usr/local/bin/"
echo "Run (needs iosc with zwlr_layer_shell_v1): see run-shell.sh"
